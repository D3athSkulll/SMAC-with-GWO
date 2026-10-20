%TESTNETWORKENV  Sanity checks for network.NetworkEnv. Run from the project root.
%   Each test uses a tiny setup whose answer can be worked out by hand.

addpath(pwd);
tol = 1e-9;

%% Test 1: coverage of one centred node ~ circle area / field area
env = network.NetworkEnv('NumNodes', 1, 'AreaSize', [100 100], 'SinkPosition', [50 50], ...
                         'SensingRadius', 20, 'CommRadius', 60, 'CoverageResolution', 0.5);
[~, m] = env.evaluate([50 50]);
expected_coverage = pi * 20^2 / (100 * 100);
assert(abs(m.coverage - expected_coverage) < 0.01, 'Test 1 failed: coverage mismatch');

%% Test 2: chain topology -> hop counts and relay load
% sink(0,0) -- n1(10,0) -- n2(20,0) -- n3(30,0), links up to 12 units long
env = network.NetworkEnv('NumNodes', 3, 'AreaSize', [100 100], 'SinkPosition', [0 0], ...
                         'SensingRadius', 5, 'CommRadius', 12);
x_chain = [10 20 30, 0 0 0];
[~, m] = env.evaluate(x_chain);
assert(isequal(m.hop_counts', [1 2 3]), 'Test 2 failed: hop counts');
assert(isequal(m.relay_load', [2 1 0]), 'Test 2 failed: relay load');
assert(m.connectivity == 1, 'Test 2 failed: connectivity');

%% Test 3: node 1 energy matches the radio model by hand
% n1 sends 3 packets (own + 2 relayed) over d = 10 and receives 2 packets.
expected_energy = env.PacketBits * (3 * (env.ElecEnergy + env.AmpEnergy * 10^2) + 2 * env.ElecEnergy);
assert(abs(m.node_energy(1) - expected_energy) < tol, 'Test 3 failed: node energy');

%% Test 4: unreachable node -> NaN hops, lower connectivity, penalty applied
x_broken = [10 20 90, 0 0 90];
[f_broken, m_broken] = env.evaluate(x_broken);
[f_chain, ~] = env.evaluate(x_chain);
assert(isnan(m_broken.hop_counts(3)), 'Test 4 failed: expected NaN hops');
assert(abs(m_broken.connectivity - 2/3) < tol, 'Test 4 failed: connectivity');
assert(f_broken > f_chain, 'Test 4 failed: disconnected layout should be worse');

%% Test 5: population evaluation shape and sanity
env = network.NetworkEnv('NumNodes', 20);
rng(42);
X = env.sampleRandom(8);
f = env.evaluatePopulation(X);
assert(isequal(size(f), [8 1]) && all(isfinite(f)) && all(f >= 0), 'Test 5 failed');

%% Test 6: out-of-range positions are clipped, not rejected
positions = env.decode([-10 500 zeros(1, 18), -10 500 zeros(1, 18)]);
assert(all(positions(:) >= 0) && all(positions(:,1) <= 100), 'Test 6 failed: clipping');

disp('All NetworkEnv tests passed.');
