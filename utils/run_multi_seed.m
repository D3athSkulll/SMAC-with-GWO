function summary = run_multi_seed(seeds, save_path)
%RUN_MULTI_SEED  Repeat GWO vs. random search over several optimiser seeds.
%
%   summary = run_multi_seed()             % seeds 1..10, saves results/multi_seed.mat
%   summary = run_multi_seed(1:5, 'out.mat')
%
%   The network and traffic stay fixed, so default S-MAC is the same in every
%   run; only the optimisers' random numbers change. Run from the project root.

    arguments
        seeds (1,:) double = 1:10
        save_path (1,1) string = fullfile("results", "multi_seed.mat")
    end

    num_seeds = numel(seeds);
    gwo_fitness = zeros(num_seeds, 1);
    random_fitness = zeros(num_seeds, 1);
    gwo_metrics = cell(num_seeds, 1);
    for k = 1:num_seeds
        r = main('Seed', seeds(k), 'Verbose', false);
        gwo_fitness(k) = r.gwo.best_fitness;
        random_fitness(k) = r.random_search.best_fitness;
        gwo_metrics{k} = r.gwo.best_metrics;
        default_fitness = r.default.fitness;
        fprintf('seed %2d: GWO %.4f | random %.4f | default %.4f\n', seeds(k), ...
                gwo_fitness(k), random_fitness(k), default_fitness);
    end

    summary = struct('seeds', seeds, 'gwo_fitness', gwo_fitness, 'random_fitness', random_fitness, ...
                     'default_fitness', default_fitness, 'gwo_metrics', {gwo_metrics}, ...
                     'gwo_wins', nnz(gwo_fitness < random_fitness));
    save(save_path, 'summary');
    fprintf('GWO mean %.4f (std %.4f) | random mean %.4f (std %.4f) | GWO better on %d of %d seeds\n', ...
            mean(gwo_fitness), std(gwo_fitness), mean(random_fitness), std(random_fitness), ...
            summary.gwo_wins, num_seeds);
end
