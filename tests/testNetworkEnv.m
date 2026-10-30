%TESTNETWORKENV  Sanity checks for network.NetworkEnv. Run from the project root.

addpath(pwd);

env = network.NetworkEnv('NumNodes', 20);
num_nodes = env.NumNodes;
sink = num_nodes + 1;

%% Test 1: every node has a route that ends at the sink
for i = 1:num_nodes
    assert(env.Routes{i}(1) == i && env.Routes{i}(end) == sink, ...
        'Test 1 failed: routes must start at their node and end at the sink');
end

%% Test 2: next hop is the second vertex of the route and is a radio neighbour
for i = 1:num_nodes
    assert(env.NextHop(i) == env.Routes{i}(2), 'Test 2 failed: next hop / route mismatch');
    assert(env.Neighbors(i, env.NextHop(i)), 'Test 2 failed: next hop out of radio range');
end

%% Test 3: hop counts are consistent along routes (next hop is one hop closer)
for i = 1:num_nodes
    next = env.NextHop(i);
    if next ~= sink
        assert(env.HopCount(next) == env.HopCount(i) - 1, 'Test 3 failed: hop count');
    else
        assert(env.HopCount(i) == 1, 'Test 3 failed: sink neighbours must be 1 hop');
    end
end

%% Test 4: neighbour matrix is symmetric, matches the radio range, no self links
points = [env.Positions; env.SinkPosition];
dist = sqrt((points(:,1) - points(:,1)').^2 + (points(:,2) - points(:,2)').^2);
assert(isequal(env.Neighbors, env.Neighbors'), 'Test 4 failed: not symmetric');
assert(~any(diag(env.Neighbors)), 'Test 4 failed: self links');
assert(isequal(env.Neighbors, dist <= env.CommRadius & ~eye(sink)), 'Test 4 failed: range');

%% Test 5: traffic is sorted, inside the generation window, close to the Poisson mean
generation_window = env.SimulationTime - env.DrainTime;
assert(issorted(env.ArrivalTimes), 'Test 5 failed: arrivals not sorted');
assert(all(env.ArrivalTimes >= 0 & env.ArrivalTimes < generation_window), 'Test 5 failed: window');
assert(all(ismember(env.ArrivalNodes, 1:num_nodes)), 'Test 5 failed: unknown source node');
expected = num_nodes * generation_window / env.PacketInterval;
assert(abs(env.numPackets() - expected) < 4 * sqrt(expected), 'Test 5 failed: packet count far from mean');

%% Test 6: the same seeds give the same network and traffic
twin = network.NetworkEnv('NumNodes', 20);
assert(isequal(twin.Positions, env.Positions) && isequal(twin.ArrivalTimes, env.ArrivalTimes), ...
    'Test 6 failed: not reproducible');
other = network.NetworkEnv('NumNodes', 20, 'DeploymentSeed', 99);
assert(~isequal(other.Positions, env.Positions), 'Test 6 failed: seed ignored');

%% Test 7: air time = 8 * bytes / rate
assert(abs(env.airTime(100) - 800 / env.DataRate) < 1e-15, 'Test 7 failed: air time');

disp('All NetworkEnv tests passed.');
