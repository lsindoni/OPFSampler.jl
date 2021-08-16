using Random

ipopt_solver = JuMP.with_optimizer(Ipopt.Optimizer, print_level=0)

is_solved(x::MOI.TerminationStatusCode) = x == MOI.LOCALLY_SOLVED || x == MOI.OPTIMAL

"""
    function DC_OPF_sampling(
        n_samples::Int,
        params::Dict;
        rng = MersenneTwister(123),
    )
# Arguments:
- `n_samples::Int`: the number of samples to be generated
- `params::Dict`: The full set of specifications for the experiment, including which functions
have to be executed.
# Keywords:
- `rng = MersenneTwister(123)`: the range from which the random numbers would be generated.
# Output
- input_cases: A vector of dictionaries containing a test case. Each dictionary corresponds
to a certain time and sequence of generated random numbers.
- params["case_network"]: The base network model in PowerModels format.
"""
function DC_OPF_sampling(
    n_samples::Int,
    params::Dict;
    rng = MersenneTwister(123),
)
    # This is the list of adjustable parameters in this class of models.
    required_keys = [
        "dev_load_pd",
        "dev_gen_max",
        "dev_rate_a",
        "dev_br_x",
        "case_network", # input in powermodels format
    ]
    if !isempty(setdiff(required_keys, keys(params)))
        err_msg = "The set of parameters is insufficient to determine the model. Missing: "
        for p in setdiff(required_keys, keys(params))
            err_msg *= "\n" * p
        end
        throw(ArgumentError(err_msg))
    end

    if (params["dev_load_pd"] < 0) || (params["dev_load_pd"] > 1)
        @error "dev_load_pd should be between 0 and 1."
    end
    if (params["dev_gen_max"] < 0) || (params["dev_gen_max"] > 1)
        @error "dev_gen_max should be between 0 and 1."
    end
    if (params["dev_rate_a"] < 0) || (params["dev_rate_a"] > 1)
        @error "dev_rate_a should be between 0 and 1."
    end
    if (params["dev_br_x"] < 0) || (params["dev_br_x"] > 1)
        @error "dev_br_x should be between 0 and 1."
    end
    # Grid specification
    ppc = deepcopy(params["case_network"])
    # We now proceed to the sampling phase
    input_cases = Vector{Dict{String, Any}}()
    sizehint!(input_cases, n_samples)

    # base load active
    base_load = [ppc["load"][k]["pd"] for k in keys(sort(ppc["load"]))]
    # base max gen
    base_gen_max = [ppc["gen"][k]["pmax"] for k in keys(sort(ppc["gen"]))]
    # base line reactance
    base_br_x = [ppc["branch"][k]["br_x"] for k in keys(sort(ppc["branch"]))]
    # base line rate
    base_rate_a = [ppc["branch"][k]["rate_a"] for k in keys(sort(ppc["branch"]))]
    for i_sample in range(1, stop = n_samples)
        # sampling load active power-This creates vector of random samples between
        # (1 - dev_load_pd) <= samples < = (1 + dev_load_pd)
        dev_load = (2 * params["dev_load_pd"]) * rand(rng, length(base_load)) .+ (1 - params["dev_load_pd"])
        new_load = dev_load .* base_load
        # sampling line rating-This creates vector of random samples between
        # (1 - dev_rate_a) <= samples < = (1 + dev_rate_a)
        dev_rate = (2 * params["dev_rate_a"]) * rand(rng, length(base_rate_a)) .+ (1 - params["dev_rate_a"])
        new_rate_a = dev_rate .* base_rate_a
        # sampling max gen-This creates vector of random samples between
        # (1 - dev_gen_max) <= samples < = (1 + dev_gen_max)
        dev_gen = (2 * params["dev_gen_max"]) * rand(rng, length(base_gen_max)) .+ (1 - params["dev_gen_max"])
        new_gen_max = dev_gen .* base_gen_max
        # sampling line reactance-This creates vector of random samples between
        # (1 - dev_br_x)*br_x <= samples < = (1 + dev_br_x)*br_x
        dev_reactance = (2 * params["dev_br_x"]) * rand(rng, length(base_br_x)) .+ (1 - params["dev_br_x"])
        new_br_x = dev_reactance .* base_br_x
        # Here we reorganize the inputs that have been computed.
        single_sample = Dict(
            "pd" => new_load,
            "pmax" => new_gen_max,
            "rate_a" => new_rate_a,
            "br_x" => new_br_x,
        )
        push!(input_cases, single_sample)
    end
    return input_cases, params["case_network"]
end


"""
    function parse_opf_settings(;settings...)

    parse the kwargs settings into a dictionary that can be passed as options for
    PowerModels.build_model.
    Usage:

    ```julia

    parse_opf_settings()

    # returns Dict("output" => Dict("branch_flows" => true))

    parse_opf_settings(;output=Dict("duals" => true))

    # returns Dict("output" => Dict("duals" => true))

    '''

    It does overwrite default configuration.

"""
function parse_opf_settings(;settings...)
    setting = Dict{String, Any}("output" => Dict("branch_flows" => true))
    for k, v in settings
        setting[String(k)] = v
    end
    return setting
end


"""
    function RunDCSampler(
        n_samples::Int,
        params::Dict;
        threshold::Float64=1.0e-5,
        rng = MersenneTwister(123),
    )
This function first triggers the DC_OPF_sampling function to generate different cases.
Then for each created sample, it updates the grid in powermodels format (not annex) and it
runs the DC-OPF and collects results.

# Arguments
- `n_samples::Int`: The number of samples (each being a full time series) to be generated
- `params::Dict`: The full set of specifications for the experiment, including which
functions
have to be executed.
# Keywords
- `threshold::Float64=1.0e-5`: The threshold used to decide if a constraint is binding or not.
- `rng = MersenneTwister(123)`: the range from which the random numbers would be generated.
# Outputs
- `samples`: Vector of samples that were generated by OPF_sampling and were fed to
  DC-OPF which containg the OPF output results too.
"""
function RunDCSampler(
    n_samples::Int,
    params::Dict;
    threshold::Float64=1.0e-5,
    rng =MersenneTwister(123),
    settings...
    )
    setting = parse_opf_settings(; settings...)
    iter = 1
    n_samples_new = n_samples
    feas_samples = []
    while iter > 0
        println("Iteration: $iter")
        samples, model = DC_OPF_sampling(n_samples_new, params; rng = rng)
        mycase = deepcopy(model)
        for sm in 1:length(samples)
            set_load_pd!(mycase, samples[sm]["pd"])
            set_gen_pmax!(mycase, samples[sm]["pmax"])
            set_dc_branch_param!(mycase, br_x = samples[sm]["br_x"],
            rate_a = samples[sm]["rate_a"])
            dc_pm = build_model(mycase, DCPPowerModel, PowerModels.post_opf, setting=setting)
            res = optimize_model!(dc_pm, ipopt_solver)
            samples[sm]["OPF_output"] = res
            println("Sample $sm out of $n_samples_new .")
        end
        # filtering out the infeasible cases
        feas_flag_new = [];
        for s_ in samples
            append!(feas_flag_new, is_solved(s_["OPF_output"]["termination_status"]));
        end
        feas_samples_new = samples[findall(feas_flag_new)];
        if iter == 1
            feas_samples = feas_samples_new
            if length(feas_samples) < n_samples/2.5 # the threshold is arbitrary
                error("The current choice of parameters lead to at least 60% infeasibilty rate on the first run. Consider changing the sampler parameters.")s
            end
        else
            feas_samples = vcat(feas_samples, feas_samples_new)
        end
        if length(feas_samples) >= n_samples
            iter_final = iter
            iter = 0
            feas_samples = feas_samples[1:n_samples]
        else
            iter += 1
            n_samples_new = n_samples - length(feas_samples);
        end
    end
    return feas_samples
end

"""
    function AC_OPF_sampling(
        n_samples::Int,
        params::Dict;
        rng = MersenneTwister(123),
    )
# Arguments:
- `n_samples::Int`: the number of samples to be generated
- `params::Dict`: The full set of specifications for the experiment, including which functions
have to be executed.
# Keywords:
- `rng = MersenneTwister(123)`: the range from which the random numbers would be generated.
# Output
- input_cases: A vector of dictionaries containing a test case. Each dictionary corresponds
to a certain time and sequence of generated random numbers.
- params["case_network"]: The base network model in PowerModels format.
"""
function AC_OPF_sampling(
    n_samples::Int,
    params::Dict;
    rng = MersenneTwister(123),
)
    # This is the list of adjustable parameters in this class of models.
    required_keys = [
        "dev_load_pd",
        "dev_load_qd",
        "dev_pgen_max",
        "dev_qgen_max",
        "dev_rate_a",
        "dev_br_x",
        "dev_br_r",
        "case_network", # input in powermodels format
    ]
    if !isempty(setdiff(required_keys, keys(params)))
        err_msg = "The set of parameters is insufficient to determine the model. Missing: "
        for p in setdiff(required_keys, keys(params))
            err_msg *= "\n" * p
        end
        throw(ArgumentError(err_msg))
    end

    if (params["dev_load_pd"] < 0) || (params["dev_load_pd"] > 1)
        @error "dev_load_pd should be between 0 and 1."
    end
    if (params["dev_load_qd"] < 0) || (params["dev_load_qd"] > 1)
        @error "dev_load_qd should be between 0 and 1."
    end
    if (params["dev_pgen_max"] < 0) || (params["dev_pgen_max"] > 1)
        @error "dev_pgen_max should be between 0 and 1."
    end
    if (params["dev_qgen_max"] < 0) || (params["dev_qgen_max"] > 1)
        @error "dev_qgen_max should be between 0 and 1."
    end
    if (params["dev_rate_a"] < 0) || (params["dev_rate_a"] > 1)
        @error "dev_rate_a should be between 0 and 1."
    end
    if (params["dev_br_x"] < 0) || (params["dev_br_x"] > 1)
        @error "dev_br_x should be between 0 and 1."
    end
    if (params["dev_br_r"] < 0) || (params["dev_br_r"] > 1)
        @error "dev_br_r should be between 0 and 1."
    end
    # Grid specification
    ppc = deepcopy(params["case_network"])
    # We now proceed to the sampling phase
    input_cases = Vector{Dict{String, Any}}()
    sizehint!(input_cases, n_samples)

    # base load active
    base_pload = [ppc["load"][k]["pd"] for k in keys(sort(ppc["load"]))]
    # base load reactive
    base_qload = [ppc["load"][k]["qd"] for k in keys(sort(ppc["load"]))]
    # base max pgen
    base_pgen_max = [ppc["gen"][k]["pmax"] for k in keys(sort(ppc["gen"]))]
    # base max qgen
    base_qgen_max = [ppc["gen"][k]["qmax"] for k in keys(sort(ppc["gen"]))]
    # base line reactance
    base_br_x = [ppc["branch"][k]["br_x"] for k in keys(sort(ppc["branch"]))]
    # base line resistance
    base_br_r = [ppc["branch"][k]["br_r"] for k in keys(sort(ppc["branch"]))]
    # base line rate
    base_rate_a = [ppc["branch"][k]["rate_a"] for k in keys(sort(ppc["branch"]))]
    for i_sample in range(1, stop = n_samples)
        # sampling load active power-This creates vector of random samples between
        # (1 - dev_load_pd) <= samples < = (1 + dev_load_pd)
        dev_pload = (2 * params["dev_load_pd"]) * rand(rng, length(base_pload)) .+ (1 - params["dev_load_pd"])
        new_pload = dev_pload .* base_pload
        # sampling load reactive power-This creates vector of random samples between
        # (1 - dev_load_qd) <= samples < = (1 + dev_load_qd)
        dev_qload = (2 * params["dev_load_qd"]) * rand(rng, length(base_qload)) .+ (1 - params["dev_load_qd"])
        new_qload = dev_qload .* base_qload
        # sampling line rating-This creates vector of random samples between
        # (1 - dev_rate_a) <= samples < = (1 + dev_rate_a)
        dev_rate = (2 * params["dev_rate_a"]) * rand(rng, length(base_rate_a)) .+ (1 - params["dev_rate_a"])
        new_rate_a = dev_rate .* base_rate_a
        # sampling max active gen-This creates vector of random samples between
        # (1 - dev_pgen_max) <= samples < = (1 + dev_pgen_max)
        dev_pgen = (2 * params["dev_pgen_max"]) * rand(rng, length(base_pgen_max)) .+ (1 - params["dev_pgen_max"])
        new_pgen_max = dev_pgen .* base_pgen_max
        # sampling max reactive gen-This creates vector of random samples between
        # (1 - dev_qgen_max) <= samples < = (1 + dev_qgen_max)
        dev_qgen = (2 * params["dev_qgen_max"]) * rand(rng, length(base_qgen_max)) .+ (1 - params["dev_qgen_max"])
        new_qgen_max = dev_qgen .* base_qgen_max
        # sampling line reactance-This creates vector of random samples between
        # (1 - dev_br_x)*br_x <= samples < = (1 + dev_br_x)*br_x
        dev_reactance = (2 * params["dev_br_x"]) * rand(rng, length(base_br_x)) .+ (1 - params["dev_br_x"])
        new_br_x = dev_reactance .* base_br_x
        # sampling line resistance-This creates vector of random samples between
        # (1 - dev_br_r)*br_r <= samples < = (1 + dev_br_r)*br_r
        dev_resistance = (2 * params["dev_br_r"]) * rand(rng, length(base_br_r)) .+ (1 - params["dev_br_r"])
        new_br_r = dev_resistance .* base_br_r
        # Here we reorganize the inputs that have been computed.
        single_sample = Dict(
            "pd" => new_pload,
            "qd" => new_qload,
            "pmax" => new_pgen_max,
            "qmax" => new_qgen_max,
            "rate_a" => new_rate_a,
            "br_x" => new_br_x,
            "br_r" => new_br_r,
        )
        push!(input_cases, single_sample)
    end
    return input_cases, params["case_network"]
end

"""
    function RunACSampler(
        n_samples::Int,
        params::Dict;
        rng = MersenneTwister(123),
    )
This function first triggers the AC_OPF_sampling function to generate different cases.
Then for each created sample, it updates the grid in powermodels format (not annex) and it
runs the AC-OPF and collects results.

# Arguments
- `n_samples::Int`: The number of samples (each being a full time series) to be generated
- `params::Dict`: The full set of specifications for the experiment, including which
functions
have to be executed.
# Keywords
- `rng = MersenneTwister(123)`: the range from which the random numbers would be generated.
# Outputs
- `samples`: Vector of samples that were generated by AC_OPF_sampling and were fed to
  AC-OPF which containg the OPF output results too.
"""
function RunACSampler(
    n_samples::Int,
    params::Dict;
    rng = MersenneTwister(123),
    settings...
    )
    setting = parse_opf_settings(; settings...)
    iter = 1
    n_samples_new = n_samples
    feas_samples = []
    while iter > 0
        println("Iteration: $iter")
        samples, model = AC_OPF_sampling(n_samples_new, params; rng = rng)
        mycase = deepcopy(model)
        for sm in 1:length(samples)
            set_load_pd!(mycase, samples[sm]["pd"])
            set_load_qd!(mycase, samples[sm]["qd"])
            set_gen_pmax!(mycase, samples[sm]["pmax"])
            set_gen_qmax!(mycase, samples[sm]["qmax"])
            set_ac_branch_param!(mycase, br_x = samples[sm]["br_x"],
            br_r = samples[sm]["br_r"], rate_a = samples[sm]["rate_a"])
            ac_pm = build_model(mycase, ACPPowerModel, PowerModels.post_opf, setting=setting)
            res = optimize_model!(ac_pm, ipopt_solver)
            samples[sm]["OPF_output"] = res
            println("Sample $sm out of $n_samples_new .")
        end
        # filtering out the infeasible cases
        feas_flag_new = [];
        for s_ in samples
            append!(feas_flag_new, is_solved(s_["OPF_output"]["termination_status"]));
        end
        feas_samples_new = samples[findall(feas_flag_new)];
        if iter == 1
            feas_samples = feas_samples_new
            if length(feas_samples) < n_samples/2.5 # the threshold is arbitrary. You can comment if wating long to generate samples is not an issue.
                error("The current choice of parameters lead to at least 60% infeasibilty rate on the first run. Consider changing the sampler parameters.")s
            end
        else
            feas_samples = vcat(feas_samples, feas_samples_new)
        end
        if length(feas_samples) >= n_samples
            iter_final = iter
            iter = 0
            feas_samples = feas_samples[1:n_samples]
        else
            iter += 1
            n_samples_new = n_samples - length(feas_samples);
        end
    end
    return feas_samples
end
