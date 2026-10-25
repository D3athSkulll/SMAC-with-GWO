function results = simulate(options, main_options)
%SIMULATE  Run SMAC-GWO and the GWO baseline with a live dual-panel figure.
%
%   results = simulate() runs main() and draws, while it runs:
%     Left  (subplot 1,2,1)  Convergence: best alpha fitness against the
%                            number of real network evaluations, for the
%                            hybrid and for plain GWO. Both runs share one
%                            axis, so a curve that drops further left
%                            reached that fitness with fewer simulations.
%     Right (subplot 1,2,2)  Network layout of the final hybrid alpha wolf:
%                            nodes, sink, transmission radii and the
%                            multi-hop routes to the sink.
%
%   results = simulate('SavePath', 'figure.png', NumNodes=25, ...)
%   simulate's own options come first; anything else is passed to main().
%
%   Uses viscircles (Image Processing Toolbox) when it is installed and
%   draws the circles with plain line objects otherwise.

    arguments
        options.SavePath (1,1) string = ""
        options.Visible (1,1) logical = true
        main_options.NumNodes
        main_options.NumWolves
        main_options.MaxIterations
        main_options.NumProposals
        main_options.EvalFraction
        main_options.StagnationLimit
        main_options.Seed
        main_options.RunBaseline
        main_options.Verbose
    end

    % --- Colours: categorical slots 1 and 2, fixed per run ---
    style.hybrid = [42 120 214] / 255;      % blue   #2a78d6
    style.baseline = [235 104 52] / 255;    % orange #eb6834
    style.ink = [0.25 0.25 0.25];           % nodes, labels
    style.muted = [0.62 0.62 0.62];         % routes, radii
    style.line_width = 2;

    fig = figure('Name', 'SMAC-GWO network optimisation', 'Color', 'w', ...
                 'Position', [100 100 1200 520], 'Visible', matlab.lang.OnOffSwitchState(options.Visible));

    % --- Panel 1: live convergence curves ---
    ax_curve = subplot(1, 2, 1, 'Parent', fig);
    hold(ax_curve, 'on');
    curves.hybrid = animatedline(ax_curve, 'Color', style.hybrid, 'LineWidth', style.line_width, ...
                                 'DisplayName', 'SMAC-GWO (hybrid)');
    curves.baseline = animatedline(ax_curve, 'Color', style.baseline, 'LineWidth', style.line_width, ...
                                   'DisplayName', 'Plain GWO (baseline)');
    styleAxes(ax_curve);
    xlabel(ax_curve, 'Real network evaluations');
    ylabel(ax_curve, 'Best alpha fitness (lower is better)');
    title(ax_curve, 'Convergence');
    legend(ax_curve, 'Location', 'northeast', 'Box', 'off');

    % Panel 2 placeholder until the hybrid finishes.
    ax_layout = subplot(1, 2, 2, 'Parent', fig);
    styleAxes(ax_layout);
    title(ax_layout, 'Network layout (waiting for the hybrid run)');

    % --- Run the optimisers; the callback feeds the live curves ---
    main_args = namedargs2cell(main_options);
    results = main(main_args{:}, 'IterationCallback', @(p) onIteration(p, curves));

    % --- Final rendering ---
    addCurveLabels(ax_curve, results, style);
    drawNetworkLayout(ax_layout, results.env, results.hybrid.best_position, style);

    if strlength(options.SavePath) > 0
        exportgraphics(fig, options.SavePath, 'Resolution', 150);
    end
end

% ======================================================================
function onIteration(progress, curves)
    % Append one point to the curve of the run that just reported.
    addpoints(curves.(progress.run), progress.evaluations, progress.alpha_fitness);
    drawnow limitrate;
end

function styleAxes(ax)
    % Recessive axes: light grid, no box, muted tick labels.
    set(ax, 'Box', 'off', 'TickDir', 'out', 'XColor', [0.45 0.45 0.45], ...
        'YColor', [0.45 0.45 0.45], 'GridColor', [0.85 0.85 0.85], 'GridAlpha', 1, ...
        'FontSize', 10);
    grid(ax, 'on');
end

function addCurveLabels(ax, results, style)
    % Direct label at the end of each curve with its final value.
    runs = {'hybrid', 'baseline'};
    for k = 1:numel(runs)
        run_name = runs{k};
        if ~isfield(results.(run_name), 'history')
            continue;
        end
        run = results.(run_name);
        x_end = run.evaluations(numel(run.history));
        y_end = run.history(end);
        plot(ax, x_end, y_end, 'o', 'MarkerSize', 7, 'MarkerFaceColor', style.(run_name), ...
             'MarkerEdgeColor', 'w', 'LineWidth', 1.5, 'HandleVisibility', 'off');
        text(ax, x_end, y_end, sprintf('  %.4f', y_end), 'Color', style.ink, ...
             'FontSize', 9, 'VerticalAlignment', 'middle');
    end
    xlim(ax, [0, max(xlim(ax)) * 1.12]);   % leave room for the end labels
    y_range = ylim(ax);
    ylim(ax, y_range + [-0.05 0.05] * diff(y_range));   % keep curves off the frame
end

function drawNetworkLayout(ax, env, alpha_pos, style)
    % Nodes, sink, transmission radii and routes of the alpha solution.
    [~, metrics] = env.evaluate(alpha_pos);
    positions = metrics.positions;
    all_points = [positions; env.SinkPosition];
    cla(ax);
    hold(ax, 'on');

    % Transmission radii (CommRadius) around every node.
    radii = env.CommRadius * ones(env.NumNodes, 1);
    if exist('viscircles', 'file') == 2
        viscircles(ax, positions, radii, 'Color', style.muted, 'LineWidth', 0.5, ...
                   'LineStyle', ':', 'EnhanceVisibility', false);
    else
        theta = linspace(0, 2 * pi, 64);
        circle_x = positions(:, 1) + radii .* cos(theta);     % N x 64 via implicit expansion
        circle_y = positions(:, 2) + radii .* sin(theta);
        plot(ax, circle_x', circle_y', ':', 'Color', style.muted, 'LineWidth', 0.5, ...
             'HandleVisibility', 'off');
    end
    plot(ax, NaN, NaN, ':', 'Color', style.muted, 'LineWidth', 1, ...
         'DisplayName', sprintf('Transmission radius (%g m)', env.CommRadius));   % legend entry

    % Routing: every hop of every shortest path, each link drawn once.
    hops = zeros(0, 2);
    for i = 1:env.NumNodes
        route = metrics.paths{i};
        if numel(route) > 1
            hops = [hops; route(1:end-1)', route(2:end)']; %#ok<AGROW>
        end
    end
    hops = unique(sort(hops, 2), 'rows');
    if ~isempty(hops)
        link_x = [all_points(hops(:, 1), 1), all_points(hops(:, 2), 1), nan(size(hops, 1), 1)]';
        link_y = [all_points(hops(:, 1), 2), all_points(hops(:, 2), 2), nan(size(hops, 1), 1)]';
        plot(ax, link_x(:), link_y(:), '-', 'Color', style.hybrid, 'LineWidth', 1.5, ...
             'DisplayName', 'Routing path');
    end

    % Nodes: connected filled, disconnected hollow (shape, not only colour).
    connected = ~isnan(metrics.hop_counts);
    scatter(ax, positions(connected, 1), positions(connected, 2), 48, style.ink, 'filled', ...
            'MarkerEdgeColor', 'w', 'LineWidth', 1, 'DisplayName', 'Sensor node');
    if any(~connected)
        scatter(ax, positions(~connected, 1), positions(~connected, 2), 48, style.ink, ...
                'LineWidth', 1.5, 'DisplayName', 'Disconnected node');
    end
    scatter(ax, env.SinkPosition(1), env.SinkPosition(2), 140, style.baseline, 's', 'filled', ...
            'MarkerEdgeColor', 'w', 'LineWidth', 1.5, 'DisplayName', 'Sink');

    axis(ax, 'equal');
    xlim(ax, [0 env.AreaSize(1)]);
    ylim(ax, [0 env.AreaSize(2)]);
    styleAxes(ax);
    xlabel(ax, 'x (m)');
    ylabel(ax, 'y (m)');
    title(ax, 'Network layout of the alpha wolf');
    subtitle(ax, sprintf('Coverage %.1f%%  |  mean latency %.0f ms  |  connectivity %.0f%%', ...
             100 * metrics.coverage, 1000 * metrics.latency, 100 * metrics.connectivity), ...
             'Color', style.ink);
    legend(ax, 'Location', 'southoutside', 'NumColumns', 2, 'Box', 'off');
end
