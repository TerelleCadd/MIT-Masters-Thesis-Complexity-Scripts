function cfgOut = build_dsm_config_no_gui(opts)
%BUILD_DSM_CONFIG_NO_GUI
%
% Overall purpose:
% This function builds a DSM-based wildfire response architecture without
% using the GUI. It loads the master SOS DSM Excel file, applies a selected
% baseline scenario, applies any user-specified multiplicity overrides,
% expands the DSM according to element multiplicities, counts interface
% types, builds a binary adjacency matrix, and returns all of the resulting
% architecture data in one output structure.
%
% In plain terms:
% - The SOS DSM spreadsheet lists the possible system elements and their
%   relationships.
% - A baseline scenario, such as Butte, Etosha, or Canada, selects which
%   elements are active and how many copies of each element exist.
% - Multiplicity overrides allow a sweep script to change asset counts
%   automatically.
% - The selected architecture is expanded so that each copy of an element
%   appears as its own row and column in the DSM.
% - Interface characters are counted so complexity metrics can be computed.
% - Cost, suppression, cycle time, and eta values are copied into the
%   expanded architecture for later performance and cost analysis.
%
% Main output:
% cfgOut is a structure containing:
%   - master DSM data
%   - selected element multiplicities
%   - expanded architecture elements
%   - expanded DSM
%   - interface counts
%   - binary adjacency matrix
%   - suppression, timing, cost, and eta vectors

    %% ---------------- Input handling and defaults ----------------
    % If the user does not pass an input structure, create an empty one.
    % This lets the function run with default settings.
    if nargin < 1 || isempty(opts)
        opts = struct();
    end

    % Set the default DSM workbook and sheet name.
    % These can be overridden by passing opts.inputFile or opts.inputSheet.
    if ~isfield(opts,'inputFile')
        opts.inputFile = 'SOS DSM.xlsx';
    end

    if ~isfield(opts,'inputSheet')
        opts.inputSheet = 'DSM';
    end

    % Use Excel column letters instead of numeric column indices.
    % This makes the code easier to check against the spreadsheet.
    %
    % CH: eta values
    % CI: suppression capability
    % CJ: suppression cycle time
    % CK: estimated asset acquisition/replacement cost
    % CL: estimated cost per use
    if ~isfield(opts,'eta_col_letter')
        opts.eta_col_letter = "CH";
    end

    if ~isfield(opts,'supp_col_letter')
        opts.supp_col_letter = "CI";
    end

    if ~isfield(opts,'cycle_col_letter')
        opts.cycle_col_letter = "CJ";
    end

    if ~isfield(opts,'assetCost_col_letter')
        opts.assetCost_col_letter = "CK";
    end

    if ~isfield(opts,'costUse_col_letter')
        opts.costUse_col_letter = "CL";
    end

    % Set the default baseline architecture.
    % Valid values are:
    %   'butte'
    %   'etosha'
    %   'canada'
    %   'none'
    if ~isfield(opts,'baseline')
        opts.baseline = 'butte';
    end

    % Optional name for the generated configuration.
    if ~isfield(opts,'name')
        opts.name = "";
    end

    % Multiplicity overrides are used by the sweep script.
    % Example:
    %   override('Fire Engines') = 500
    %
    % If this is empty, the baseline multiplicities are used directly.
    if ~isfield(opts,'multOverrides')
        opts.multOverrides = [];
    end

    %% ---------------- Cached load of the master DSM workbook ----------------
    % Reading an Excel file thousands of times during a grid sweep is slow.
    % Persistent variables stay in memory between function calls, so the DSM
    % is only reloaded when the input file, sheet, or column selections change.
    persistent MASTER_CACHE MASTER_KEY

    % The cache key uniquely identifies the workbook configuration.
    % If any part of this key changes, the function reloads the spreadsheet.
    key = string(opts.inputFile) + "|" + string(opts.inputSheet) + "|" + ...
          string(opts.eta_col_letter) + "|" + string(opts.supp_col_letter) + "|" + ...
          string(opts.cycle_col_letter) + "|" + string(opts.assetCost_col_letter) + "|" + ...
          string(opts.costUse_col_letter);

    % Load the master DSM only if the cache is empty or outdated.
    if isempty(MASTER_KEY) || MASTER_KEY ~= key
        fprintf("[build_dsm_config_no_gui] Loading master DSM from Excel (cached)...\n");

        % Read the full Excel sheet as a cell array.
        raw = readcell(opts.inputFile, 'Sheet', opts.inputSheet);

        % First column contains element names.
        % Row 1 is treated as a header, so elements start at row 2.
        elements = clean_string(string(raw(2:end, 1)));

        % The DSM itself starts in row 2, column 2.
        DSM0 = raw(2:end, 2:end);

        % Remove blank or missing element names.
        % The matching DSM rows and columns also need to be removed so the
        % element list and DSM stay aligned.
        bad = ismissing(elements) | strlength(elements)==0;
        if any(bad)
            warning("Found %d blank/missing element names in DSM list. Dropping those rows/cols.", nnz(bad));
            elements(bad) = [];
            DSM0(bad,:)   = [];
            DSM0(:,bad)   = [];
        end

        % Number of master elements in the cleaned DSM.
        n0 = size(DSM0,1);

        % Convert the spreadsheet column letters into numeric indices.
        eta_col   = excel_col_to_idx(opts.eta_col_letter);
        supp_col  = excel_col_to_idx(opts.supp_col_letter);
        cycle_col = excel_col_to_idx(opts.cycle_col_letter);

        assetCost_col = excel_col_to_idx(opts.assetCost_col_letter);
        costUse_col   = excel_col_to_idx(opts.costUse_col_letter);

        % Read numeric element attributes from the selected columns.
        % Each vector is aligned with the master element list.
        eta_master       = get_numeric_col(raw, n0, eta_col,       "eta");
        suppress_master  = get_numeric_col(raw, n0, supp_col,      "suppress_val");
        cycle_master     = get_numeric_col(raw, n0, cycle_col,     "cycle_days");
        assetCost_master = get_numeric_col(raw, n0, assetCost_col, "asset_cost_usd_est");
        costUse_master   = get_numeric_col(raw, n0, costUse_col,   "cost_per_use_usd_est");

        % Normalize the DSM cell entries.
        % Blank or missing cells become empty strings.
        % Nonblank cells are converted to trimmed strings.
        DSM_master = cell(n0,n0);
        for i = 1:n0
            for j = 1:n0
                v = DSM0{i,j};

                if isBlankDSMCell(v)
                    DSM_master{i,j} = "";
                else
                    DSM_master{i,j} = strtrim(string(v));
                end
            end
        end

        % Store the cleaned master data in the persistent cache.
        MASTER_CACHE = struct();
        MASTER_CACHE.elements          = elements(:);
        MASTER_CACHE.DSM_master        = DSM_master;
        MASTER_CACHE.eta_master        = eta_master(:);
        MASTER_CACHE.suppress_master   = suppress_master(:);
        MASTER_CACHE.cycle_master      = cycle_master(:);
        MASTER_CACHE.assetCost_master  = assetCost_master(:);
        MASTER_CACHE.costUse_master    = costUse_master(:);

        % Save the key so future calls know whether the cache is still valid.
        MASTER_KEY = key;
    end

    %% ---------------- Pull cached data into local variables ----------------
    % These variables are easier to work with than repeatedly referencing
    % fields of MASTER_CACHE.
    elements        = MASTER_CACHE.elements;
    DSM_master      = MASTER_CACHE.DSM_master;
    eta_master      = MASTER_CACHE.eta_master;
    suppress_master = MASTER_CACHE.suppress_master;
    cycle_master    = MASTER_CACHE.cycle_master;

    assetCost_master = MASTER_CACHE.assetCost_master;
    costUse_master   = MASTER_CACHE.costUse_master;

    n0 = numel(elements);

    %% ---------------- Build baseline multiplicities ----------------
    % mult_master stores how many copies of each master element exist.
    % include_master stores whether each master element is included.
    %
    % By default:
    %   - multiplicity is set to 1
    %   - elements are excluded until the baseline map turns them on
    mult_master = ones(n0,1);
    include_master = false(n0,1);

    baselineKey = lower(string(opts.baseline));

    % Select the baseline map based on opts.baseline.
    % The map contains element names and their baseline multiplicities.
    switch baselineKey
        case "butte"
            baseMap = butte_county_baseline_map();

        case "etosha"
            baseMap = etosha_baseline_map();

        case {"canada","uscanadian","us_canadian","us/canadian"}
            baseMap = canada_baseline_map();

        case "none"
            % The "none" option includes every element once.
            % This is useful for debugging or for full-taxonomy studies.
            include_master(:) = true;
            mult_master(:)    = 1;
            baseMap = [];

        otherwise
            error("opts.baseline must be 'butte', 'etosha', 'canada', or 'none'");
    end

    % If a named baseline is being used, loop over all master elements.
    % Elements found in the baseline map are included with the map value.
    % Elements not found in the baseline map are excluded.
    if ~strcmpi(baselineKey,'none')
        for i = 1:n0
            nmS = elements(i);

            if ismissing(nmS) || strlength(nmS)==0
                continue;
            end

            nm = char(nmS);

            if isKey(baseMap, nm)
                include_master(i) = true;
                mult_master(i)    = max(0, baseMap(nm));
            else
                include_master(i) = false;
                mult_master(i)    = 1;
            end
        end
    end

    %% ---------------- Apply multiplicity overrides ----------------
    % Overrides let another script change the baseline asset counts.
    % This is what allows the architecture sweep to test many configurations.
    %
    % Example:
    %   baseline says Fire Engines = 622
    %   sweep override says Fire Engines = 522
    %
    % The override replaces the baseline value.
    if ~isempty(opts.multOverrides)

        % Apply the override values and track which elements were changed.
        [mult_master, overriddenMask] = apply_mult_overrides(elements, mult_master, opts.multOverrides);

        % If an overridden element has positive multiplicity, include it.
        % If the override sets it to zero, exclude it.
        include_master(overriddenMask) = (mult_master(overriddenMask) > 0);

        % Final safety check:
        % no element should be included if its multiplicity is zero.
        include_master = include_master & (mult_master > 0);
    end

    %% ---------------- Expand the architecture by multiplicity ----------------
    % Find the master element indices that are active in this configuration.
    includedIdx = find(include_master & mult_master > 0);

    % Expanded arrays store one row per actual element copy.
    %
    % Example:
    % If Fire Engines has multiplicity 3, then "Fire Engines" appears three
    % times in expandedElements.
    expandedElements      = strings(0,1);
    expandedEta           = [];
    expandedSupp          = [];
    expandedCycleDays     = [];
    expandedAssetCostUSD  = [];
    expandedCostPerUseUSD = [];

    % expansionMap records which master element each expanded element came from.
    % This is needed when building the expanded DSM.
    expansionMap = [];

    for ii = 1:numel(includedIdx)
        origIdx = includedIdx(ii);
        m       = mult_master(origIdx);
        nmS     = elements(origIdx);

        if ismissing(nmS) || strlength(nmS)==0
            error("Master element name is missing/blank at master index %d", origIdx);
        end

        % Replicate this master element m times.
        for jj = 1:m
            expandedElements(end+1,1) = nmS; 

            % Store the original master index for DSM lookup.
            expansionMap(end+1,1) = origIdx; 

            % Replicate element-level attributes.
            expandedEta(end+1,1)       = eta_master(origIdx); 
            expandedSupp(end+1,1)      = suppress_master(origIdx); 
            expandedCycleDays(end+1,1) = cycle_master(origIdx); 

            % Replicate cost attributes.
            expandedAssetCostUSD(end+1,1)  = assetCost_master(origIdx);
            expandedCostPerUseUSD(end+1,1) = costUse_master(origIdx); 
        end
    end

    %% ---------------- Build the expanded DSM ----------------
    % N is the total number of expanded elements after multiplicity is applied.
    N = numel(expandedElements);

    % The expanded DSM has one row and column for every expanded element.
    expandedDSM = cell(N,N);

    % Each expanded element points back to a master element through expansionMap.
    % Therefore, the expanded DSM entry is copied from the corresponding
    % master DSM entry.
    for r = 1:N
        for c = 1:N
            expandedDSM{r,c} = DSM_master{expansionMap(r), expansionMap(c)};
        end
    end

    %% ---------------- Count interface characters ----------------
    % The DSM stores interface types as characters in each cell.
    % For example, a cell might contain "IM" if there are information and
    % mass interfaces.
    %
    % compute_interface_counts returns:
    %   interfaceChars  = all unique interface codes present
    %   interfaceCounts = how many times each interface code is received by
    %                     each expanded element row
    [interfaceChars, interfaceCounts] = compute_interface_counts(expandedDSM);

    %% ---------------- Build binary adjacency matrix ----------------
    % A is a simple graph-style representation of the DSM.
    %
    % A(i,j) = 1 means element i has at least one interface with element j.
    % A(i,j) = 0 means no interface is present.
    %
    % This matrix is used for topology-based complexity calculations.
    A = zeros(N,N);

    for i = 1:N
        for j = 1:N
            entry = expandedDSM{i,j};

            if (isstring(entry) || ischar(entry)) && strlength(strtrim(string(entry))) > 0
                A(i,j) = 1;
            end
        end
    end

    % Remove self-loops.
    % Even if the DSM diagonal has entries, topology metrics generally should
    % not count an element as connected to itself.
    A(1:N+1:end) = 0;

    %% ---------------- Package output structure ----------------
    % Return everything needed by the sweep, complexity, performance, and
    % cost scripts.
    cfgOut = struct();

    % Configuration name.
    cfgOut.name = string(opts.name);

    % Master-level data.
    cfgOut.elements_master = elements;
    cfgOut.DSM_master      = DSM_master;

    cfgOut.eta_master      = eta_master;
    cfgOut.suppress_master = suppress_master;
    cfgOut.cycle_master    = cycle_master;

    cfgOut.assetCost_master  = assetCost_master;
    cfgOut.costPerUse_master = costUse_master;

    % Master-level scenario selection.
    cfgOut.mult_master    = mult_master;
    cfgOut.include_master = include_master;

    % Expanded architecture data.
    cfgOut.expandedElements  = expandedElements;
    cfgOut.expandedEta       = expandedEta(:);
    cfgOut.expandedSuppVal   = expandedSupp(:);
    cfgOut.expandedCycleDays = expandedCycleDays(:);

    % Expanded cost data.
    cfgOut.expandedAssetCostUSD  = expandedAssetCostUSD(:);
    cfgOut.expandedCostPerUseUSD = expandedCostPerUseUSD(:);

    % Expanded DSM.
    cfgOut.expandedDSM = expandedDSM;

    % Interface-code information.
    cfgOut.interfaceChars  = interfaceChars;
    cfgOut.interfaceCounts = interfaceCounts;

    % Binary topology matrix.
    cfgOut.A = A;
end

%% ========================================================================
% Helper functions
% ========================================================================

function idx = excel_col_to_idx(colLetter)
%EXCEL_COL_TO_IDX Converts an Excel column letter into a numeric index.
%
% Example:
%   A  -> 1
%   B  -> 2
%   Z  -> 26
%   AA -> 27
%   CH -> 86

    colLetter = upper(char(string(colLetter)));
    idx = 0;

    for i = 1:numel(colLetter)
        idx = idx*26 + (double(colLetter(i)) - double('A') + 1);
    end
end

function [mult_master, overriddenMask] = apply_mult_overrides(elements, mult_master, overrides)
%APPLY_MULT_OVERRIDES Replaces baseline multiplicities with user overrides.
%
% Supported override formats:
%   1. containers.Map
%   2. struct
%   3. table with columns Element and Multiplicity
%
% overriddenMask marks which elements were explicitly changed.

    n0 = numel(elements);
    overriddenMask = false(n0,1);

    if isa(overrides,'containers.Map')
        % Case 1:
        % Overrides are stored in a containers.Map where keys are element
        % names and values are multiplicities.
        keys = string(overrides.keys);

        for k = 1:numel(keys)
            nm = clean_string(keys(k));
            idx = find(elements == nm, 1);

            if isempty(idx)
                warning("Override name not found: %s", nm);
                continue;
            end

            mult_master(idx) = max(0, overrides(char(nm)));
            overriddenMask(idx) = true;
        end

    elseif isstruct(overrides)
        % Case 2:
        % Overrides are stored as structure fields.
        f = fieldnames(overrides);

        for k = 1:numel(f)
            nm = clean_string(string(f{k}));
            idx = find(elements == nm, 1);

            if isempty(idx)
                warning("Override name not found: %s", nm);
                continue;
            end

            mult_master(idx) = max(0, overrides.(f{k}));
            overriddenMask(idx) = true;
        end

    elseif istable(overrides)
        % Case 3:
        % Overrides are stored as a table.
        if ~all(ismember(["Element","Multiplicity"], string(overrides.Properties.VariableNames)))
            error("Override table must have columns: Element, Multiplicity");
        end

        for k = 1:height(overrides)
            nm = clean_string(string(overrides.Element(k)));
            idx = find(elements == nm, 1);

            if isempty(idx)
                warning("Override name not found: %s", nm);
                continue;
            end

            mult_master(idx) = max(0, overrides.Multiplicity(k));
            overriddenMask(idx) = true;
        end

    else
        error("Unsupported overrides type.");
    end
end

function [chars, counts] = compute_interface_counts(DSMcell)
%COMPUTE_INTERFACE_COUNTS Finds and counts interface-code characters.
%
% The expanded DSM stores interface types as characters.
% This helper:
%   1. scans the full DSM to find every unique interface character
%   2. counts how many times each character appears in each row
%
% The row-wise counts are later used to compute interface complexity.

    N = size(DSMcell,1);

    % Collect every interface character that appears anywhere in the DSM.
    allLetters = char([]);

    for i = 1:N
        for j = 1:N
            entry = string(DSMcell{i,j});

            if strlength(strtrim(entry)) == 0
                continue;
            end

            allLetters = [allLetters, char(entry)];
        end
    end

    % If there are no interface characters, return an empty result.
    if isempty(allLetters)
        chars  = char([]);
        counts = zeros(N,0);
        return;
    end

    % Keep only visible characters and preserve the order in which unique
    % interface codes first appear.
    allLetters = allLetters(:);
    allLetters = allLetters(isstrprop(allLetters,'graphic'));
    chars = unique(allLetters,'stable')';

    k = numel(chars);

    % counts(i,kk) is the number of times interface character kk appears in
    % row i of the expanded DSM.
    counts = zeros(N,k);

    for i = 1:N
        for j = 1:N
            entry = string(DSMcell{i,j});

            if strlength(strtrim(entry)) == 0
                continue;
            end

            es = char(entry);

            for kk = 1:k
                counts(i,kk) = counts(i,kk) + count(es, chars(kk));
            end
        end
    end
end

function x = get_numeric_col(raw, n0, colIdx, label)
%GET_NUMERIC_COL Reads a numeric column from the raw Excel cell array.
%
% The DSM data starts on row 2, so this function reads rows 2 through n0+1.
% Non-numeric entries are converted using robustToDouble.

    x = nan(n0,1);

    % If the workbook does not contain the requested column, return NaNs.
    if size(raw,2) < colIdx
        warning("%s column (col %d) not found. Filling with NaN.", label, colIdx);
        return;
    end

    vv = raw(2:1+n0, colIdx);

    for i = 1:n0
        x(i) = robustToDouble(vv{i});
    end
end

function tf = isBlankDSMCell(v)
%ISBLANKDSMCELL Returns true if a DSM cell should be treated as blank.

    if isnumeric(v)
        tf = isempty(v) || (isscalar(v) && isnan(v));
        return;
    end

    s = string(v);
    tf = (ismissing(s) || strlength(strtrim(s))==0);
end

function x = robustToDouble(v)
%ROBUSTTODOUBLE Converts common spreadsheet values into a scalar double.
%
% Handles:
%   - numeric values
%   - logical values
%   - character/string numeric entries
%
% Returns NaN if conversion fails.

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

function s = clean_string(x)
%CLEAN_STRING Standardizes element names from Excel or user input.
%
% This removes leading/trailing spaces and nonbreaking spaces, which often
% appear when copying text from spreadsheets or documents.

    s = strtrim(erase(string(x), char(160)));
end

function mp = butte_county_baseline_map()
%BUTTE_COUNTY_BASELINE_MAP Returns baseline element multiplicities for Butte.
%
% The map contains only elements included in the Butte County baseline.
% Any element not listed here is excluded from the Butte baseline.

    buttePairs = { ...
        'Very Large Air Tankers', 1; ...
        'Large Air Tankers', 2; ...
        'Single Engine Airtankers', 4; ...
        'Helicopters Type I', 6; ...
        'Helicopters Type II', 8; ...
        'Helicopters Type III', 10; ...
        'Tactical Lead Planes', 2; ...
        'Smokejumper Aircraft', 1; ...
        'Tactical UAS', 3; ...
        'EO Satellites (OroraTech)', 3; ...
        'Weather Satellites (GOES-16/GOES-18)', 2; ...
        'Comms Satellites (Iridium)', 1; ...
        'Satellite Imagery Systems (VIIRS Pipeline)', 1; ...
        'Fire Engines', 622; ...
        'Airbase Support Systems', 2; ...
        'C3 Systems', 1; ...

        % Functional elements
        'Deploy Air Assets', 1; ...
        'Lead Tankers', 1; ...
        'Supervise Air Attacks (AAGs)', 1; ...
        'Drop Water', 1; ...
        'Drop Fire Retardant', 1; ...
        'Perform Post-Drop Assessment', 1; ...
        'Dispatch To Reloading Base', 1; ...
        'Deploy Ground Assets', 1; ...
        'Establish Containment Lines', 1; ...
        'Spill Water from Ground Assets', 1; ...
        'Tactically Monitor Fires', 1; ...
        'Predict New Fires', 1; ...
        'Detect Fires', 1; ...
        'Visually Confirm Fires', 1; ...
        'Predict Fire Paths/Behavior', 1; ...
        'Strategically Monitor Fires', 1; ...
        'Gather Real Time Data from Assets', 1; ...
        'Build Real Time Situational Awareness', 1; ...
        'Coordinate Air & Ground Resources', 1; ...
        'Dynamically Allocate Resources', 1; ...
        'Issue Commands to Assets', 1; ...
        'Communicate to Resources', 1; ...
        'Maintain Communication Among Assets', 1; ...
        'Maintain Communication Between Assets and C3', 1; ...
        'Deploy First Response Ground Assets', 1; ...
        'Deploy Smokejumpers', 1; ...
        'Activate MAFFS', 1; ...
        'Refuel Airborne Assets', 1; ...
        'Provide MRO for Assets', 1; ...
        'Refill Water and Fire Retardants', 1; ...
        'Provide Logistic Support to Crews', 1; ...

        % Organizational elements
        'Federal Emergency Management Agency', 1; ...
        'National Interagency Fire Center', 1; ...
        'US Forest Service', 1; ...
        'Bureau Of Land Management (BLM)', 1; ...
        'National Park Service (NPS)', 1; ...
        'US Fish & Wildlife Services (USFWS)', 1; ...
        'Bureau Of Indian Affairs (BIA)', 1; ...
        'US Department of Defense (DOD)', 1; ...
        'Military Organizations (US National Guard/DOD)', 1; ...
        'Local Fire Departments', 1; ...
        'Volunteer Firefighting Organizations', 2; ...
        'Private Aircraft Operators', 2; ...
        'National Weather Service (NWS)', 1; ...
        'National Oceanic & Atmospheric Admin (NOAA)', 1; ...
        'FAA', 1; ...
        'U.S. Federal Government', 1; ...
        'State Governors'' Offices', 1; ...
    };

    mp = containers.Map(buttePairs(:,1), cell2mat(buttePairs(:,2)));
end

function mp = etosha_baseline_map()
%ETOSHA_BASELINE_MAP Returns baseline element multiplicities for Etosha.
%
% This baseline represents a lower-resource wildfire response architecture.

    etoshaPairs = { ...
        'Large Air Tankers', 1; ...
        'Single Engine Airtankers', 2; ...
        'Helicopters Type I', 1; ...
        'Tactical UAS', 9; ...
        'HAPS', 1; ...
        'EO Satellites (OroraTech)', 4; ...
        'Weather Satellites (GOES-16/GOES-18)', 1; ...
        'Comms Satellites (Iridium)', 1; ...
        'Satellite Imagery Systems (VIIRS Pipeline)', 1; ...
        'Fire Engines', 91; ...
        'Airbase Support Systems', 1; ...
        'C3 Systems', 1; ...

        % Functional elements
        'Deploy Air Assets', 1; ...
        'Lead Tankers', 1; ...
        'Supervise Air Attacks (AAGs)', 1; ...
        'Drop Water', 1; ...
        'Drop Fire Retardant', 1; ...
        'Perform Post-Drop Assessment', 1; ...
        'Dispatch To Reloading Base', 1; ...
        'Deploy Ground Assets', 1; ...
        'Establish Containment Lines', 1; ...
        'Spill Water from Ground Assets', 1; ...
        'Tactically Monitor Fires', 1; ...
        'Predict New Fires', 1; ...
        'Detect Fires', 1; ...
        'Visually Confirm Fires', 1; ...
        'Predict Fire Paths/Behavior', 1; ...
        'Strategically Monitor Fires', 1; ...
        'Gather Real Time Data from Assets', 1; ...
        'Build Real Time Situational Awareness', 1; ...
        'Coordinate Air & Ground Resources', 1; ...
        'Dynamically Allocate Resources', 1; ...
        'Issue Commands to Assets', 1; ...
        'Communicate to Resources', 1; ...
        'Maintain Communication Among Assets', 1; ...
        'Maintain Communication Between Assets and C3', 1; ...
        'Deploy First Response Ground Assets', 1; ...
        'Refuel Airborne Assets', 1; ...
        'Provide MRO for Assets', 1; ...
        'Refill Water and Fire Retardants', 1; ...
        'Provide Logistic Support to Crews', 1; ...

        % Organizational and support elements
        'Environmental Protection Agency', 1; ...
        'Satellite Manufacturers', 1; ...
        'UAS Manufacturers', 1; ...
        'C3 Systems Suppliers', 1; ...
        'Communication Systems Suppliers', 1; ...
        'Geospatial Information System Companies', 1; ...
        'Cloud Service Providers', 1; ...
        'Firefighting Equipment Suppliers', 1; ...
        'Fire Engines Manufacturers', 1; ...
        'Local Fire Departments', 1; ...
        'Volunteer Firefighting Organizations', 1; ...
        'Private Aircraft Operators', 1; ...
    };

    mp = containers.Map(etoshaPairs(:,1), cell2mat(etoshaPairs(:,2)));
end

function mp = canada_baseline_map()
%CANADA_BASELINE_MAP Returns baseline element multiplicities for Canada.
%
% This baseline represents a binational or internationally supported wildfire
% response architecture.

    canadaPairs = { ...
        'Very Large Air Tankers', 2; ...
        'Large Air Tankers', 2; ...
        'Single Engine Airtankers', 3; ...
        'Water Scoopers', 4; ...
        'Military Airborne Firefighting System', 1; ...
        'Helicopters Type I', 4; ...
        'Helicopters Type II', 4; ...
        'Helicopters Type III', 2; ...
        'Tactical Lead Planes', 2; ...
        'Air Attack Group Supervisor (AAGS)', 1; ...
        'Tactical UAS', 4; ...
        'HAPS', 1; ...
        'EO Satellites (OroraTech)', 8; ...
        'Weather Satellites (GOES-16/GOES-18)', 3; ...
        'Comms Satellites (Iridium)', 1; ...
        'Satellite Imagery Systems (VIIRS Pipeline)', 1; ...
        'Fire Engines', 40; ...
        'Airbase Support Systems', 3; ...
        'C3 Systems', 1; ...

        % Functional elements
        'Deploy Air Assets', 1; ...
        'Lead Tankers', 1; ...
        'Supervise Air Attacks (AAGs)', 1; ...
        'Drop Water', 1; ...
        'Drop Fire Retardant', 1; ...
        'Perform Post-Drop Assessment', 1; ...
        'Dispatch To Reloading Base', 1; ...
        'Deploy Ground Assets', 1; ...
        'Establish Containment Lines', 1; ...
        'Spill Water from Ground Assets', 1; ...
        'Tactically Monitor Fires', 1; ...
        'Predict New Fires', 1; ...
        'Detect Fires', 1; ...
        'Visually Confirm Fires', 1; ...
        'Predict Fire Paths/Behavior', 1; ...
        'Strategically Monitor Fires', 1; ...
        'Gather Real Time Data from Assets', 1; ...
        'Build Real Time Situational Awareness', 1; ...
        'Coordinate Air & Ground Resources', 1; ...
        'Dynamically Allocate Resources', 1; ...
        'Issue Commands to Assets', 1; ...
        'Communicate to Resources', 1; ...
        'Maintain Communication Among Assets', 1; ...
        'Maintain Communication Between Assets and C3', 1; ...
        'Deploy First Response Ground Assets', 1; ...
        'Deploy Smokejumpers', 1; ...
        'Activate MAFFS', 1; ...
        'Refuel Airborne Assets', 1; ...
        'Provide MRO for Assets', 1; ...
        'Refill Water and Fire Retardants', 1; ...
        'Provide Logistic Support to Crews', 1; ...

        % Organizational and governance elements
        'Environmental Protection Agency', 1; ...
        'Military Organizations (US National Guard/DOD)', 1; ...
        'Manufacturers Of VLAT/LAT', 1; ...
        'Manufacturers Of Lead Plane & AAGS', 1; ...
        'Satellite Manufacturers', 1; ...
        'UAS Manufacturers', 1; ...
        'C3 Systems Suppliers', 1; ...
        'Communication Systems Suppliers', 1; ...
        'Geospatial Information System Companies', 1; ...
        'Cloud Service Providers', 1; ...
        'Firefighting Equipment Suppliers', 1; ...
        'Fire Engines Manufacturers', 1; ...
        'Local Fire Departments', 1; ...
        'Volunteer Firefighting Organizations', 3; ...
        'Private Aircraft Operators', 3; ...
        'National Weather Service (NWS)', 1; ...
        'National Oceanic & Atmospheric Admin (NOAA)', 1; ...
        'FAA', 1; ...
        'State Governors'' Offices', 1; ...
        'Provincial Emergency Agencies (e.g., Ontario EMO)', 1; ...
        'Canadian Interagency Forest Fire Centre (CIFFC)', 1; ...
        'Global Affairs Canada', 1; ...
        'U.S. Department of State', 1; ...
        'U.S. Federal Government', 1; ...
        'Government of Canada', 1; ...
        'Federal Emergency Management Agency', 1; ...
        'National Interagency Fire Center', 1; ...
        'US Forest Service', 1; ...
        'US Department of Defense (DOD)', 1; ...
    };

    mp = containers.Map(canadaPairs(:,1), cell2mat(canadaPairs(:,2)));
end