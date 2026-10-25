%TESTPIPELINE  Sanity checks for the hybrid SMAC-GWO pipeline. Run from the project root.

addpath(pwd);
rng(3);

%% Test 1: multi-proposal mode returns K stacked blocks and counts one iteration
engine = optimizer.GWOEngine([0 0 0], [1 1 1], 'NumWolves', 6, 'MaxIterations', 10);
positions = engine.initializePack();
engine.receiveFitness(positions, sum(positions.^2, 2));
proposals = engine.proposeCandidates(4);
assert(isequal(size(proposals), [24 3]), 'Test 1 failed: proposal block size');
assert(engine.Iteration == 1, 'Test 1 failed: iteration counter');
assert(all(proposals(:) >= 0 & proposals(:) <= 1), 'Test 1 failed: bounds');

%% Test 2: predicted (unevaluated) wolves never become leaders or count as evaluations
evals_before = engine.NumEvaluations;
fake = -1e6 * ones(6, 1);                       % absurdly good surrogate guesses
is_evaluated = [true; false(5, 1)];
fake(1) = 5;
engine.receiveFitness(proposals(1:6, :), fake, is_evaluated);
assert(engine.AlphaFitness > -1e6, 'Test 2 failed: predicted wolf became alpha');
assert(engine.NumEvaluations == evals_before + 1, 'Test 2 failed: evaluation count');

%% Test 3: hybrid run is elitist and spends fewer evaluations than plain GWO iterations would
results = main('NumNodes', 8, 'NumWolves', 12, 'MaxIterations', 10, ...
               'NumProposals', 4, 'Verbose', false);
hybrid = results.hybrid;
assert(all(diff(hybrid.history) <= 0), 'Test 3 failed: hybrid best fitness got worse');
assert(hybrid.num_evaluations < 12 * 11, 'Test 3 failed: surrogate did not save evaluations');
assert(hybrid.evaluations(end) == hybrid.num_evaluations, 'Test 3 failed: evaluation history');
assert(any(isfinite(hybrid.surrogate_rmse)), 'Test 3 failed: no surrogate RMSE recorded');

%% Test 4: baseline gets no more real evaluations than the hybrid
assert(results.baseline.num_evaluations <= hybrid.num_evaluations, 'Test 4 failed: unfair budget');

disp('All pipeline tests passed.');
