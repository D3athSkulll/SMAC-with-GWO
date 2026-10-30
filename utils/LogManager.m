classdef LogManager < handle
    %LOGMANAGER  Structured command-window logging for the optimisers.
    %
    %   Prints a fixed-width table, one row per iteration, plus timestamped
    %   info/warning lines. The columns are defined by the caller as a struct
    %   array with fields name, width and format (an sprintf format). NaN
    %   values are shown as "-". All output goes through fprintf to a file id
    %   (1 = command window), so a log file can be used instead.
    %
    %   Typical use:
    %       columns = struct('name', {'Iteration', 'Best Fitness'}, ...
    %                        'width', {9, 12}, 'format', {'%d', '%.5f'});
    %       logger = LogManager("GWO", columns);
    %       logger.header();
    %       logger.row({iter, best_fitness});
    %       logger.footer();

    properties (SetAccess = immutable)
        Title           % name shown above the table
        Columns         % struct array: name, width, format
        FileId          % fprintf target, 1 = command window
        Enabled         % false silences every method
        PrintEvery      % print every PrintEvery-th row (the first row is always printed)
    end

    properties (SetAccess = private)
        StartTime       % tic value taken by header()
        RowCount = 0    % rows received since header()
    end

    methods
        function obj = LogManager(title, columns, options)
            arguments
                title (1,1) string = "Optimizer"
                columns struct = struct('name', {'Iteration', 'Best Fitness'}, ...
                                        'width', {9, 12}, 'format', {'%d', '%.6f'})
                options.FileId (1,1) double = 1
                options.Enabled (1,1) logical = true
                options.PrintEvery (1,1) double {mustBeInteger, mustBePositive} = 1
            end
            assert(all(isfield(columns, {'name', 'width', 'format'})), 'LogManager:badColumns', ...
                'columns needs the fields name, width and format.');
            obj.Title = title;
            obj.Columns = columns(:)';
            obj.FileId = options.FileId;
            obj.Enabled = options.Enabled;
            obj.PrintEvery = options.PrintEvery;
            obj.StartTime = tic;
        end

        function header(obj)
            %HEADER  Title, column names and a separator line.
            obj.StartTime = tic;
            obj.RowCount = 0;
            if ~obj.Enabled, return; end
            fprintf(obj.FileId, '\n== %s ==\n', obj.Title);
            obj.printRule();
            cells = arrayfun(@(c) obj.pad(c.name, c.width, 'left'), obj.Columns, 'UniformOutput', false);
            fprintf(obj.FileId, '| %s |\n', strjoin(cells, ' | '));
            obj.printRule();
        end

        function row(obj, values)
            %ROW  One table row; values is a cell with one entry per column.
            assert(numel(values) == numel(obj.Columns), 'LogManager:badRow', ...
                'Expected %d values, got %d.', numel(obj.Columns), numel(values));
            obj.RowCount = obj.RowCount + 1;
            if ~obj.Enabled || mod(obj.RowCount - 1, obj.PrintEvery) ~= 0, return; end
            cells = cell(1, numel(values));
            for k = 1:numel(values)
                value = values{k};
                if isnumeric(value) && isscalar(value) && isnan(value)
                    text = '-';
                else
                    text = sprintf(obj.Columns(k).format, value);
                end
                cells{k} = obj.pad(text, obj.Columns(k).width, 'right');
            end
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
            dashes = arrayfun(@(c) repmat('-', 1, c.width + 2), obj.Columns, 'UniformOutput', false);
            fprintf(obj.FileId, '+%s+\n', strjoin(dashes, '+'));
        end
    end

    methods (Static, Access = private)
        function text = pad(text, width, justify)
            %PAD  Fit text into a fixed-width column ('left' or 'right' justified).
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
