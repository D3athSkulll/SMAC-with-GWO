classdef NetworkEnv
    %NETWORKENV  Wireless sensor network (WSN) placement problem.
    %
    %   Decision vector (length 2N):  x = [x_1 ... x_N, y_1 ... y_N]
    %   Each sensor node has a 2-D position inside a rectangular field.
    %   One fixed sink (base station) collects data from every node.
    %
    %   Three objectives are measured and combined into one scalar
    %   fitness (lower is better):
    %
    %     1. Latency   - mean hop count from each node to the sink
    %     2. Energy    - energy of the busiest node (network lifetime proxy)
    %     3. Coverage  - fraction of the field inside some sensing disc
    %
    %   Routing is minimum-energy multi-hop: a link exists between two
    %   nodes if they are within CommRadius, and its cost is distance^2.
    %   Shortest paths to the sink are found with Dijkstra (MATLAB graph).
    %
    %   Typical use:
    %       env = network.NetworkEnv('NumNodes', 20);
    %       x   = env.sampleRandom(1);
    %       [fitness, metrics] = env.evaluate(x);
    %
    %   Requires MATLAB R2019b or newer (arguments block, implicit expansion).

    properties (SetAccess = immutable)
        % --- Geometry ---
        NumNodes            % number of sensor nodes (N)
        AreaSize            % [width height] of the field
        SinkPosition        % [x y] of the sink / base station
        SensingRadius       % radius of each node's sensing disc
        CommRadius          % max distance for a direct radio link
        CoverageResolution  % spacing of the grid used to measure coverage
        GridPoints          % M x 2 coverage sample points (precomputed)

        % --- First-order radio energy model (Heinzelman et al.) ---
        PacketBits          % bits per data packet
        ElecEnergy          % J/bit spent in TX or RX electronics
        AmpEnergy           % J/bit/m^2 spent in the TX amplifier

        % --- Latency model ---
        HopDelay            % seconds added by each hop

        % --- Scalarisation ---
        Weights             % [w_latency w_energy w_coverage], sums to 1
        DisconnectPenalty   % extra cost per unit of disconnected nodes
    end

    methods
        function obj = NetworkEnv(options)
            arguments
                options.NumNodes (1,1) double {mustBeInteger, mustBePositive} = 20
                options.AreaSize (1,2) double {mustBePositive} = [100 100]
                options.SinkPosition double = []
                options.SensingRadius (1,1) double {mustBePositive} = 15
                options.CommRadius (1,1) double {mustBePositive} = 25
                options.CoverageResolution (1,1) double {mustBePositive} = 2
                options.PacketBits (1,1) double {mustBePositive} = 4000
                options.ElecEnergy (1,1) double {mustBePositive} = 50e-9
                options.AmpEnergy (1,1) double {mustBePositive} = 100e-12
                options.HopDelay (1,1) double {mustBePositive} = 0.01
                options.Weights (1,3) double {mustBeNonnegative} = [0.25 0.25 0.50]
                options.DisconnectPenalty (1,1) double {mustBeNonnegative} = 1
            end

            obj.NumNodes = options.NumNodes;
            obj.AreaSize = options.AreaSize;

            % Default sink: centre of the field.
            if isempty(options.SinkPosition)
                obj.SinkPosition = options.AreaSize / 2;
            else
                sink = reshape(options.SinkPosition, 1, []);
                assert(numel(sink) == 2 && all(sink >= 0) && all(sink <= options.AreaSize), ...
                    'NetworkEnv:badSink', 'SinkPosition must be [x y] inside the field.');
                obj.SinkPosition = sink;
            end

            assert(sum(options.Weights) > 0, 'NetworkEnv:badWeights', ...
                'At least one objective weight must be positive.');
            obj.Weights = options.Weights / sum(options.Weights);

            obj.SensingRadius = options.SensingRadius;
            obj.CommRadius = options.CommRadius;
            obj.CoverageResolution = options.CoverageResolution;
            obj.PacketBits = options.PacketBits;
            obj.ElecEnergy = options.ElecEnergy;
            obj.AmpEnergy = options.AmpEnergy;
            obj.HopDelay = options.HopDelay;
            obj.DisconnectPenalty = options.DisconnectPenalty;

            % Coverage is estimated on a regular grid of sample points.
            [grid_x, grid_y] = meshgrid(0:options.CoverageResolution:options.AreaSize(1), ...
                                        0:options.CoverageResolution:options.AreaSize(2));
            obj.GridPoints = [grid_x(:), grid_y(:)];
        end

        % ------------------------------------------------------------
        %  Search-space helpers (used later by the optimizer)
        % ------------------------------------------------------------
        function lb = lowerBounds(obj)
            lb = zeros(1, 2 * obj.NumNodes);
        end

        function ub = upperBounds(obj)
            ub = [repmat(obj.AreaSize(1), 1, obj.NumNodes), ...
                  repmat(obj.AreaSize(2), 1, obj.NumNodes)];
        end

        function X = sampleRandom(obj, num_samples)
            %SAMPLERANDOM  Uniform random solutions, one per row.
            lb = obj.lowerBounds();
            ub = obj.upperBounds();
            X = lb + rand(num_samples, numel(lb)) .* (ub - lb);
        end

        function positions = decode(obj, x)
            %DECODE  Vector [x_1..x_N, y_1..y_N] -> N x 2 matrix.
            %   Out-of-range values are clipped to the field. This is the
            %   boundary handling an optimizer can rely on.
            x = reshape(x, 1, []);
            assert(numel(x) == 2 * obj.NumNodes, 'NetworkEnv:badSize', ...
                'Expected a vector of length %d.', 2 * obj.NumNodes);
            x = min(max(x, obj.lowerBounds()), obj.upperBounds());
            positions = [x(1:obj.NumNodes)', x(obj.NumNodes+1:end)'];
        end

        % ------------------------------------------------------------
        %  Objective function
        % ------------------------------------------------------------
        function [fitness, metrics] = evaluate(obj, x)
            %EVALUATE  Scalar fitness (lower is better) plus a metrics struct.
            num_nodes = obj.NumNodes;
            sink_index = num_nodes + 1;     % sink is the last vertex in the graph

            positions = obj.decode(x);
            all_points = [positions; obj.SinkPosition];
            dist = obj.pairwiseDistances(all_points);

            % --- Routing: shortest path from every node to the sink ---
            [paths, is_connected] = obj.buildRoutes(dist, sink_index);

            % --- Latency ---
            % A node that cannot reach the sink gets the worst case (N hops).
            hop_counts = nan(num_nodes, 1);
            for i = find(is_connected)'
                hop_counts(i) = numel(paths{i}) - 1;
            end
            hops_filled = hop_counts;
            hops_filled(isnan(hops_filled)) = num_nodes;
            mean_latency = mean(hops_filled) * obj.HopDelay;
            latency_norm = mean(hops_filled) / num_nodes;

            % --- Energy ---
            [node_energy, relay_load] = obj.computeEnergy(paths, is_connected, dist);
            peak_energy = max(node_energy);
            energy_norm = peak_energy / obj.worstCaseNodeEnergy();

            % --- Coverage ---
            coverage = obj.computeCoverage(positions);

            % --- Connectivity ---
            connectivity = mean(is_connected);

            % --- Scalarised fitness ---
            fitness = obj.Weights(1) * latency_norm ...
                    + obj.Weights(2) * energy_norm ...
                    + obj.Weights(3) * (1 - coverage) ...
                    + obj.DisconnectPenalty * (1 - connectivity);

            if nargout > 1
                metrics = struct( ...
                    'fitness',      fitness, ...
                    'latency',      mean_latency, ...
                    'latency_norm', latency_norm, ...
                    'energy',       peak_energy, ...
                    'energy_norm',  energy_norm, ...
                    'coverage',     coverage, ...
                    'connectivity', connectivity, ...
                    'hop_counts',   hop_counts, ...
                    'relay_load',   relay_load, ...
                    'node_energy',  node_energy, ...
                    'paths',        {paths}, ...
                    'positions',    positions);
            end
        end

        function fitness = evaluatePopulation(obj, X)
            %EVALUATEPOPULATION  Fitness for each row of X (pop_size x 2N).
            %   Routing differs per solution so this is a plain loop; the
            %   heavy math inside evaluate() is vectorized.
            pop_size = size(X, 1);
            fitness = zeros(pop_size, 1);
            for k = 1:pop_size
                fitness(k) = obj.evaluate(X(k, :));
            end
        end
    end

    methods (Access = private)
        function dist = pairwiseDistances(~, points)
            %PAIRWISEDISTANCES  Euclidean distance matrix via implicit expansion.
            dx = points(:,1) - points(:,1)';
            dy = points(:,2) - points(:,2)';
            dist = sqrt(dx.^2 + dy.^2);
        end

        function [paths, is_connected] = buildRoutes(obj, dist, sink_index)
            %BUILDROUTES  Min-energy multi-hop routes from each node to the sink.
            %   Edge exists if distance <= CommRadius, edge cost = distance^2
            %   (transmit energy grows with d^2, so this favours short hops).
            num_nodes = obj.NumNodes;
            link_exists = (dist <= obj.CommRadius) & ~eye(num_nodes + 1);
            edge_cost = (dist.^2 + eps) .* link_exists;   % eps keeps zero-distance links valid
            graph_net = graph(edge_cost);

            paths = cell(num_nodes, 1);
            is_connected = false(num_nodes, 1);
            for i = 1:num_nodes
                route = shortestpath(graph_net, i, sink_index);
                if ~isempty(route)
                    paths{i} = route;
                    is_connected(i) = true;
                end
            end
        end

        function [node_energy, relay_load] = computeEnergy(obj, paths, is_connected, dist)
            %COMPUTEENERGY  Energy per node for one reporting round.
            %   Every connected node sends one packet to the sink. For each
            %   hop a -> b on its path:
            %       a pays  bits * (E_elec + E_amp * d^2)   (transmit)
            %       b pays  bits * E_elec                   (receive, if b is not the sink)
            num_nodes = obj.NumNodes;
            node_energy = zeros(num_nodes, 1);
            relay_load = zeros(num_nodes, 1);   % packets a node forwards for others

            for i = find(is_connected)'
                route = paths{i};
                tx_nodes = route(1:end-1);
                rx_nodes = route(2:end);

                hop_dist = dist(sub2ind(size(dist), tx_nodes, rx_nodes));
                tx_energy = obj.PacketBits * (obj.ElecEnergy + obj.AmpEnergy * hop_dist.^2);
                node_energy(tx_nodes) = node_energy(tx_nodes) + tx_energy(:);

                receivers = rx_nodes(rx_nodes <= num_nodes);   % drop the sink
                node_energy(receivers) = node_energy(receivers) + obj.PacketBits * obj.ElecEnergy;

                relays = route(2:end-1);
                relay_load(relays) = relay_load(relays) + 1;
            end
        end

        function coverage = computeCoverage(obj, positions)
            %COMPUTECOVERAGE  Fraction of grid points within SensingRadius of any node.
            dx = obj.GridPoints(:,1) - positions(:,1)';   % M x N
            dy = obj.GridPoints(:,2) - positions(:,2)';
            is_covered = any(dx.^2 + dy.^2 <= obj.SensingRadius^2, 2);
            coverage = mean(is_covered);
        end

        function energy_ref = worstCaseNodeEnergy(obj)
            %WORSTCASENODEENERGY  Upper bound used to normalise energy to ~[0,1].
            %   One node forwards all N packets at maximum link length.
            n = obj.NumNodes;
            tx = n * obj.PacketBits * (obj.ElecEnergy + obj.AmpEnergy * obj.CommRadius^2);
            rx = (n - 1) * obj.PacketBits * obj.ElecEnergy;
            energy_ref = tx + rx;
        end
    end
end
