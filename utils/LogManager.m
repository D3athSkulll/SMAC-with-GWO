classdef LogManager < handle
    %LOGMANAGER  Structured command-window logging for the optimisers.
    %
    %   Prints one table row per iteration:
    %       Iteration | Best Alpha Fitness | Surrogate RMSE | Diversity Index | Evals
    %   plus timestamped info/warning lines. All output goes through
    %   fprintf to a file id (1 = command window), so a log file can be
    %   used instead.
    %
    %   Typical use:
    %       log = LogManager('Hybrid SMAC-GWO');
    %       log.header();
    %       log.iteration(iter, alpha_fitness, rmse, diversity, evaluations);
    %       log.footer();

    properties (SetAccess = immutable)
        Title           % name shown above the table
        FileId          % fprintf target, 1 = command window
        Enabled         % false silences every method
        PrintEvery      % print one row every PrintEvery iterations
    end

    properties (Constant, Access = private)
        ColumnWidths = [9 20 16 17 7]
        ColumnNames = {'Iteration', 'Best Alpha Fitness', 'Surrogate RMSE', ...
                       'Diversity Index', 'Evals'}
    end

    properties (SetAccess = private)
        StartTime       % tic value taken by header()
    end

    methods
        function obj = LogManager(title, options)
            arguments
                title (1,1) string = "Optimizer"
                options.FileId (1,1) double = 1
                options.Enabled (1,1) logical = true
                options.PrintEvery (1,1) double {mustBeInteger, mustBePositive} = 1
            end
            obj.Title = title;
            obj.FileId = options.FileId;
            obj.Enabled = options.Enabled;
            obj.PrintEvery = options.PrintEvery;
            obj.StartTime = tic;
        end

        function header(obj)
            %HEADER  Title, column names and a separator line.
            obj.StartTime = tic;
            if ~obj.Enabled, return; end
            fprintf(obj.FileId, '\n== %s ==\n', obj.Title);
            obj.printRule();
            cells = arrayfun(@(k) obj.pad(obj.ColumnNames{k}, obj.ColumnWidths(k)), ...
                             1:numel(obj.ColumnWidths), 'UniformOutput', false);
            fprintf(obj.FileId, '| %s |\n', strjoin(cells, ' | '));
            obj.printRule();
        end

        function iteration(obj, iter, alpha_fitness, rmse, diversity, evaluations)
            %ITERATION  One table row. NaN RMSE is shown as "-" (no model yet).
            if ~obj.Enabled || mod(iter, obj.PrintEvery) ~= 0, return; end
            if isnan(rmse)
                rmse_text = '-';
            else
                rmse_text = sprintf('%.5f', rmse);
            end
            values = {sprintf('%d', iter), sprintf('%.6f', alpha_fitness), rmse_text, ...
                      sprintf('%.4f', diversity), sprintf('%d', evaluations)};
            cells = arrayfun(@(k) obj.pad(values{k}, obj.ColumnWidths(k), 'right'), ...
                             1:numel(values), 'UniformOutput', false);
            fprintf(obj.FileId, '| %s |\n', strjoin(cells, ' | '));
        end

        function footer(obj)
            %FOOTER  Closing line with the elapsed wall-clock time.
            if ~obj.Enabled, return; end
            obj.printRule();
            fprintf(obj.FileId, '%s finished in %.1f s\n', obj.Title, toc(obj.StartTime));
        end

        function info(obj, message, varargin)
            obj.printLine('INFO', message, varargin{:});
        end

        function warn(obj, message, varargin)
            obj.printLine('WARN', message, varargin{:});
        end
    end

    methods (Access = private)
        function printLine(obj, level, message, varargin)
            if ~obj.Enabled, return; end
            stamp = char(datetime('now', 'Format', 'HH:mm:ss'));
            fprintf(obj.FileId, '[%s] %-4s %s\n', stamp, level, sprintf(message, varargin{:}));
        end

        function printRule(obj)
            dashes = arrayfun(@(w) repmat('-', 1, w + 2), obj.ColumnWidths, 'UniformOutput', false);
            fprintf(obj.FileId, '+%s+\n', strjoin(dashes, '+'));
        end
    end

    methods (Static, Access = private)
        function text = pad(text, width, justify)
            %PAD  Fit text into a fixed-width column ('left' or 'right' justified).
            if nargin < 3, justify = 'left'; end
            text = char(text);
            if numel(text) > width
                text = text(1:width);
            elseif strcmp(justify, 'right')
                text = [repmat(' ', 1, width - numel(text)), text];
            else
                text = [text, repmat(' ', 1, width - numel(text))];
            end
        end
    end
end
