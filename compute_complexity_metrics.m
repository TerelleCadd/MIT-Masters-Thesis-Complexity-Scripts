function out = compute_complexity_metrics(cfg, opts)
%COMPUTE_COMPLEXITY_METRICS
%
% Overall purpose:
% This function computes the complexity metrics for one wildfire response
% architecture configuration. It takes the expanded architecture output from
% build_dsm_config_no_gui.m and calculates:
%
%   C1: element complexity
%   C2: interface complexity
%   C3: topological complexity
%   total complexity: C1 + adjusted C2/C3 interaction term
%
% In plain terms:
% - C1 measures how complex the selected elements are.
% - C2 measures how complex the interfaces between those elements are.
% - C3 measures how connected or coupled the architecture topology is.
% - The final total combines these values into one architecture-level
%   complexity score.
%
% Main inputs:
% cfg  = architecture configuration structure created by
%        build_dsm_config_no_gui.m
%
% opts = optional settings for the Excel file, sheet names, interface-code
%        labels, and interface-weight range
%
% Main output:
% out = structure containing the number of expanded elements, C1 vector,
%       C2 vector, C1 sum, C2 sum, C3 value, and total complexity score

    %% ---------------- Handle optional input settings ----------------
    % If the user does not pass an options structure, create an empty one.
    if nargin < 2 || isempty(opts)
        opts = struct();
    end

    % Default Excel file that stores the C1 scores and C2 interface weights.
    if ~isfield(opts,'c1_file')
        opts.c1_file = 'Wildfire Response Function Criticality.xlsx';
    end

    % Sheet containing element-level C1 values.
    if ~isfield(opts,'c1_sheet')
        opts.c1_sheet = 'C1 Summary';
    end

    % Sheet containing interface-type weights.
    if ~isfield(opts,'c2_sheet')
        opts.c2_sheet = 'C2 Interface Weights';
    end

    % Excel range containing interface type names and their weights.
    if ~isfield(opts,'c2_range')
        opts.c2_range = 'E11:F26';
    end

    %% ---------------- Define interface codes ----------------
    % These are the short codes used inside the DSM cells.
    % Each code represents a different type of interface.
    %
    % Example:
    %   I = Information
    %   M = Mass
    %   E = Energy
    if ~isfield(opts,'interface_codes')
        opts.interface_codes = {'I','M','H','E','c','D','S','O','R','C','F','L','Y','X','P'};
    end

    % Map each DSM interface code to the full interface label used in the
    % Excel weight table.
    %
    % This lets the function connect a DSM code like 'I' to the corresponding
    % weight for "Information".
    if ~isfield(opts,'code_to_label') || isempty(opts.code_to_label)
        opts.code_to_label = containers.Map( ...
            {'M','H','E','I','c','D','O','S','R','C','F','L','X','Y','P'}, ...
            {'Mass','Physical','Energy','Information','Contribution','Development', ...
             'Operation','Service','Prerequisite','Coordination','Financial','Legal', ...
             'Contractual','Deliverable','Political'} );
    end

    %% ---------------- Cached read of C1 values and C2 weights ----------------
    % Reading the Excel file repeatedly during a large architecture sweep is
    % slow. Persistent variables keep the C1 values and C2 weights in memory
    % after the first read.
    persistent C1_CACHE WEIGHTS_CACHE CACHE_KEY

    % This key identifies the specific Excel file, sheets, and range being used.
    % If any part changes, the function reloads the Excel data.
    key = string(opts.c1_file) + "|" + string(opts.c1_sheet) + "|" + ...
          string(opts.c2_sheet) + "|" + string(opts.c2_range);

    % Reload Excel data only if the cache is empty or the settings changed.
    if isempty(CACHE_KEY) || CACHE_KEY ~= key

        %% -------- Read C1 element scores --------
        % Read the C1 summary sheet as raw cells.
        rawC1 = readcell(opts.c1_file, 'Sheet', opts.c1_sheet);

        % Element names start in row 3, column 1.
        rawNames = rawC1(3:end,1);

        % The C1 value is assumed to be in the last column of the C1 sheet.
        rawVals = rawC1(3:end,end);

        % Clean the element names so spacing issues do not break matching.
        allC1_names = clean_string(string(rawNames));

        % Convert the C1 values into doubles.
        allC1_vals = nan(numel(allC1_names),1);

        for i = 1:numel(allC1_names)
            allC1_vals(i) = robustToDouble(rawVals{i});
        end

        % Store C1 values in a map:
        %   key   = element name
        %   value = C1 score
        C1_CACHE = containers.Map('KeyType','char','ValueType','double');

        for i = 1:numel(allC1_names)
            nmS = allC1_names(i);

            % Skip blank names and missing C1 values.
            if ismissing(nmS) || strlength(nmS)==0 || isnan(allC1_vals(i))
                continue;
            end

            C1_CACHE(char(nmS)) = allC1_vals(i);
        end

        %% -------- Read C2 interface weights --------
        % Read the interface weight table from the selected sheet/range.
        % The expected format is:
        %   column 1 = interface type label
        %   column 2 = interface weight
        weights_raw = readtable(opts.c1_file, ...
            'Sheet', opts.c2_sheet, ...
            'Range', opts.c2_range, ...
            'ReadVariableNames', false);

        % Store the interface weights in a simple table with clear names.
        WEIGHTS_CACHE = table;
        WEIGHTS_CACHE.InterfaceType = string(weights_raw{:,1});
        WEIGHTS_CACHE.Weight        = weights_raw{:,2};

        % Mark the cache as valid for the current settings.
        CACHE_KEY = key;
    end

    % Use the cached weights table.
    weights_table = WEIGHTS_CACHE;

    %% ---------------- Pull architecture inputs from cfg ----------------
    % Expanded element names from the architecture configuration.
    names = clean_string(cfg.expandedElements(:));

    % Eta controls how element complexity and interface complexity are balanced.
    eta = cfg.expandedEta(:);

    % Binary adjacency matrix used for topology complexity.
    A = cfg.A;

    % Number of expanded elements in this configuration.
    n = numel(names);

    %% ---------------- Compute raw C1 vector ----------------
    % C1_vec_raw stores the unweighted C1 score for each expanded element.
    C1_vec_raw = nan(n,1);

    for i = 1:n
        nmS = names(i);

        % Every expanded element must have a valid name.
        if ismissing(nmS) || strlength(nmS)==0
            error("Expanded element name is missing/blank at index %d.", i);
        end

        nm = char(nmS);

        % Every expanded element must have a C1 score in the C1 Excel sheet.
        if ~isKey(C1_CACHE, nm)
            error("Missing C1 value for element: %s", nmS);
        end

        C1_vec_raw(i) = C1_CACHE(nm);
    end

    %% ---------------- Compute raw C2 vector ----------------
    % cfg.interfaceChars contains the interface codes found in the expanded DSM.
    % cfg.interfaceCounts tells how many times each code appears for each row.
    chars  = cfg.interfaceChars(:)';
    counts = cfg.interfaceCounts;

    % Build a lookup table that maps each interface code to its column in
    % cfg.interfaceCounts.
    code_to_col = containers.Map('KeyType','char','ValueType','double');

    for k = 1:numel(chars)
        code_to_col(chars(k)) = k;
    end

    % C2_vec_raw stores the unweighted interface burden for each element.
    C2_vec_raw = zeros(n,1);

    % Loop through all interface codes defined in opts.interface_codes.
    for iCode = 1:numel(opts.interface_codes)
        code = char(opts.interface_codes{iCode});

        % Skip codes that do not have a label mapping.
        if ~isKey(opts.code_to_label, code)
            continue;
        end

        % Skip codes that do not appear in the expanded DSM.
        if ~isKey(code_to_col, code)
            continue;
        end

        % Convert the short DSM code into the full interface label.
        label = string(opts.code_to_label(code));

        % Find the matching row in the interface weight table.
        widx = strcmpi(weights_table.InterfaceType, label);

        % Skip this interface if no weight is found.
        if ~any(widx)
            continue;
        end

        % Get the interface weight.
        w = weights_table.Weight(find(widx,1));

        % Get the matching column in the interface count matrix.
        col = code_to_col(code);

        % Add this interface type's weighted contribution to each element.
        C2_vec_raw = C2_vec_raw + counts(:,col) .* w;
    end

    %% ---------------- Apply eta weighting ----------------
    % The eta vector must align with the expanded element list.
    if numel(eta) ~= n
        error("eta length mismatch.");
    end

    % C1 is scaled by eta.
    % A higher eta places more emphasis on element complexity.
    C1_vec = 2*eta(:) .* C1_vec_raw(:);

    % C2 is scaled by 1 - eta.
    % A lower eta places more emphasis on interface complexity.
    C2_vec = 2*(1-eta(:)) .* C2_vec_raw(:);

    %% ---------------- Compute C3 topological complexity ----------------
    % C3 is computed from the singular values of the binary adjacency matrix.
    % This captures the overall coupling/topological structure of the
    % architecture.
    C3 = sum(svd(double(A)));

    %% ---------------- Compute total complexity ----------------
    % Sum element complexity over all expanded elements.
    C1_sum = sum(C1_vec);

    % Sum interface complexity over all expanded elements.
    C2_sum = sum(C2_vec);

    % Total complexity combines:
    %   1. element complexity
    %   2. interface complexity
    %   3. topology complexity
    %
    % Dividing by n normalizes the C2*C3 interaction by architecture size.
    total = C1_sum + (C2_sum * C3 / n);

    %% ---------------- Package outputs ----------------
    out = struct();

    % Preserve configuration name if one exists.
    if isfield(cfg,'name')
        out.name = string(cfg.name);
    else
        out.name = "";
    end

    % Store all main complexity outputs.
    out.n      = n;
    out.C1_vec = C1_vec;
    out.C2_vec = C2_vec;
    out.C1_sum = C1_sum;
    out.C2_sum = C2_sum;
    out.C3     = C3;
    out.total  = total;
end

%% ========================================================================
% Helper functions
% ========================================================================

function s = clean_string(x)
%CLEAN_STRING Standardizes names read from Excel or cfg.
%
% This removes leading/trailing spaces and nonbreaking spaces. It helps avoid
% matching errors caused by invisible spreadsheet formatting characters.

    s = strtrim(erase(string(x), char(160)));
end

function x = robustToDouble(v)
%ROBUSTTODOUBLE Converts common spreadsheet cell values into doubles.
%
% Handles:
%   - numeric scalar values
%   - logical values
%   - character/string values that contain numbers
%
% Returns NaN if the value cannot be converted.

    x = nan;

    if isnumeric(v) && isscalar(v) && ~isnan(v)
        x = v;

    elseif islogical(v) && isscalar(v)
        x = double(v);

    elseif ischar(v) || isstring(v)
        vv = str2double(strtrim(string(v)));

        if ~isnan(vv)
            x = vv;
        end
    end
end