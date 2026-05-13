   % =========================================================================
% Script Name: DSMParseV3.m
% Author: Terelle Cadd
% Date: 02/24/2026
%
% Description:
% This script reads a wildfire response Design Structure Matrix (DSM) from
% Excel, allows the user to select which system elements are included in a
% scenario, expands the DSM based on element multiplicity, and prepares the
% selected architecture for downstream complexity and performance analysis.
%
% The script also connects the architecture representation to the wildfire
% performance model. After the user selects a scenario, it assigns the
% scenario-specific fire location, map settings, STK observation settings,
% perimeter timing assumptions, natural decay assumptions, suppression
% settings, and output file names.
%
% Main tasks completed in this section:
%   1. Define input and output Excel files.
%   2. Configure performance model settings.
%   3. Load DSM elements and interface data.
%   4. Load eta, suppression capability, and suppression cycle time columns.
%   5. Define scenario presets for Butte County, Etosha, and US/Canada.
%   6. Open a GUI where the user can include/exclude elements and adjust
%      multiplicities, suppression values, and cycle times.
%   7. Apply selected scenario-specific fire and STK configuration values.
% =========================================================================

% Clear the command window, remove all variables, and close open figures so
% the script starts from a clean MATLAB workspace.
clc; clear; close all;

%% === INPUT SETTINGS ===
% Excel file containing the DSM and element information.
inputFile    = 'SOS DSM.xlsx';

% Sheet containing the DSM matrix.
inputSheet   = 'DSM';

% Output file for the expanded DSM matrix.
outputDSM    = 'Expanded_DSM_Matrix.xlsx';

% Output file for interface count summaries.
outputCount  = 'DSM_Interface_Counts.xlsx';

% Sheet name used inside the interface count output file.
outputSheet  = 'Counts';

%% Hierarchy plot toggle
% Controls whether a hierarchy plot is generated later in the script.
doPlotHierarchy = false;

%% === PERFORMANCE INTEGRATION TOGGLES ===
% Controls whether the selected DSM architecture is passed to the wildfire
% performance model.
doRunPerformance = true;

% Excel file and sheet where performance outputs are written.
perfOutXlsx      = 'Performance_Output.xlsx';
perfOutSheet     = 'ScenarioOutput';

% Create the performance configuration structure. Scenario-specific values
% are assigned later after the user selects a scenario in the GUI.
perfCfg = struct();

% Google Static Maps API key used by the wildfire performance model to
% download map imagery for perimeter alignment.
perfCfg.apiKey   = "YOUR_GOOGLE_API_KEY_GOES_HERE";

% Generic fire-location defaults. These are initialized as NaN because the
% actual values depend on the selected scenario.
perfCfg.ignLat   = NaN;
perfCfg.ignLon   = NaN;
perfCfg.zoom0    = NaN;

% Default Google Static Maps image size and scale factor.
perfCfg.mapW     = 640;
perfCfg.mapH     = 480;
perfCfg.scale    = 2;

% By default, the performance model asks the user to select the fire
% screenshot interactively.
perfCfg.useGUIForScreenshot = true;
perfCfg.snapFile = "";

% Default output files created by the fire perimeter alignment workflow.
perfCfg.outOverlay = "aligned_overlay.png";
perfCfg.outMask    = "perimeter_mask_warped.png";
perfCfg.outCSV     = "fire_perimeter_latlon.csv";
perfCfg.outKML     = "fire_perimeter.kml";

% Minimum number of feature-matching inliers required for map registration.
perfCfg.minInliersAccept = 12;

% Controls whether the performance model creates figures.
perfCfg.doFigures = true;

% Post-perimeter and suppression simulation defaults.
perfCfg.dayPerimeter        = NaN;
perfCfg.plotSuppression     = true;
perfCfg.supp_dtHours        = 0.25;   % 15-minute resolution
perfCfg.supp_tMaxDays       = 100;
perfCfg.naturalHalfLifeDays = 2;

%% === STK OBSERVATION METRICS TOGGLES ===
% Controls whether the script computes or loads satellite observation metrics
% from STK.
doRunSTKObs = true;

% Default STK observation cache file. This is overwritten later with a
% scenario-specific cache filename.
stkObsCacheFile = 'stk_obs_cache.mat';

% Initialize STK scenario timing and fire target settings. Scenario-specific
% values are assigned after GUI selection.
stkStartStr   = '';
stkStopStr    = '';
stkFireLat    = NaN;
stkFireLon    = NaN;
stkFireAlt_km = 0;

% Maximum number of EO satellites to include when building the observation
% cache.
stkMaxEO = 8;

%% === DETECTION DELAY WHAT-IF SETTINGS ===
% Controls whether delay cases are evaluated.
doDelaySweep = true;

% Controls whether delay cases are plotted together.
plotDelayComparison = true;

% Manual delay cases in days. These correspond to 0, 2, 4, 8, and 12 hours.
perfCfg.detectionDelayDaysVec = [0; 2/24; 4/24; 8/24; 12/24];

% Optional fallback growth slope in acres/day if the growth curve cannot be
% used to estimate a delay penalty.
perfCfg.delaySlopeAcresPerDay = NaN;

% Controls whether a full nominal run is completed before fast-mode delay
% analysis.
doNominalFigureRun = true;

%% === STEP 1: Load DSM Data ===
% Read the full DSM sheet into a cell array so text, numbers, and blanks can
% all be handled.
raw        = readcell(inputFile, 'Sheet', inputSheet);

% The first column after the header contains the element names.
elements   = raw(2:end, 1);

% The DSM itself starts in row 2, column 2.
DSM_data   = raw(2:end, 2:end);

% Number of elements in the DSM.
numElems   = size(DSM_data, 1);

% === Load eta from column CH (col 86) ===
% Eta is used later as an element/interface scaling factor.
eta_col = 86;

% Stop if the expected eta column does not exist.
if size(raw,2) < eta_col
    error('Eta column CH (col %d) not found in sheet. Check that eta is in column CH.', eta_col);
end

% Read eta values from the Excel sheet.
eta_raw = raw(2:1+numElems, eta_col);
eta_orig = nan(numElems,1);

% Convert each eta value to a numeric value using a robust conversion helper.
for i = 1:numElems
    eta_orig(i) = robustToDouble(eta_raw{i});
end

% Warn the user if any eta values could not be converted.
if any(isnan(eta_orig))
    warning('Some eta values are NaN (check CH2:CH%d for blanks/non-numeric).', 1+numElems);
end

% === Load suppression capability from column CI (col 87), interpreted as acres/use ===
% Suppression capability represents how many acres each use of an asset can
% suppress in the performance model.
supp_col  = 87;
supp_orig = nan(numElems,1);

% Read suppression values if the column exists.
if size(raw,2) >= supp_col
    supp_raw = raw(2:1+numElems, supp_col);

    % Convert each suppression value to a number.
    for i = 1:numElems
        supp_orig(i) = robustToDouble(supp_raw{i});
    end

    % Warn if some suppression values are missing or nonnumeric.
    if any(isnan(supp_orig))
        warning('Some suppression capability values are NaN (check CI2:CI%d for blanks/non-numeric).', 1+numElems);
    end
else
    % If the column is missing, keep suppression values as NaN.
    warning('Suppression column CI (col %d) not found. Filling suppression capability with NaN.', supp_col);
    supp_orig(:) = nan;
end

% === Load suppression cycle interval from column CK (col 88), days ===
% Cycle days represent the time between repeated uses of a suppression asset.
cycle_col  = 88;
cycle_orig = nan(numElems,1);

% Read cycle-time values if the column exists.
if size(raw,2) >= cycle_col
    cycle_raw = raw(2:1+numElems, cycle_col);

    % Convert each cycle-time value to a number.
    for i = 1:numElems
        cycle_orig(i) = robustToDouble(cycle_raw{i});
    end

    % Warn if some cycle-time values are missing or nonnumeric.
    if any(isnan(cycle_orig))
        warning('Some cycle_days values are NaN (check CK2:CK%d for blanks/non-numeric).', 1+numElems);
    end
else
    % If the column is missing, keep cycle values as NaN.
    warning('Cycle column CK (col %d) not found. Filling cycle_days with NaN.', cycle_col);
    cycle_orig(:) = nan;
end

%% === SCENARIO PRESETS (Include + Multiplicity ONLY) ===
% Scenario presets define the baseline architecture for each wildfire case.
% Each pair contains an element name and the multiplicity used for that
% scenario.

scenarioPresets = struct();

% Butte County baseline architecture.
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
    'EO Satellites (OroraTech)', 8; ...
    'Weather Satellites (GOES-16/GOES-18)', 0; ...
    'Comms Satellites (Iridium)', 1; ...
    'Satellite Imagery Systems (VIIRS Pipeline)', 1; ...
    'Fire Engines', 622; ...
    'Airbase Support Systems', 2; ...
    'C3 Systems', 1; ...

    % Functional elements.
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

    % Organizational elements.
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

% Convert the Butte pair list into a map so element names can be looked up
% quickly when the preset is applied.
scenarioPresets.ButteCounty_mult = containers.Map(buttePairs(:,1), cell2mat(buttePairs(:,2)));

% Etosha National Park baseline architecture. This represents a lower-
% resource, more remote wildfire response scenario.
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

    % Functional elements.
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

    % Organizational and ecosystem support elements.
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

% Convert the Etosha pair list into a lookup map.
scenarioPresets.Etosha_mult = containers.Map(etoshaPairs(:,1), cell2mat(etoshaPairs(:,2)));

% US/Canadian wildfire baseline architecture. This represents a larger
% binational response case with more aircraft, organizations, and support
% entities.
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

    % Functional elements.
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

    % Organizational and governance elements.
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
    'US Department of Defense (DOD)', 1;
    };

% Convert the US/Canada pair list into a lookup map.
scenarioPresets.USCanadianWildfires_mult = containers.Map(canadaPairs(:,1), cell2mat(canadaPairs(:,2)));

%% === STEP 2: GUI for Include / Multiplicity / Suppression / CycleDays ===
% Initialize each element as included by default.
included      = num2cell(true(numElems, 1));

% Initialize each element with multiplicity of one.
multiplicity  = num2cell(ones(numElems, 1));

% Load original suppression capability and cycle-time values into editable
% GUI columns.
suppCap       = num2cell(supp_orig(:));
cycleDays     = num2cell(cycle_orig(:));

% Combine element names and editable properties into one table for the GUI.
cellData      = [elements, included, multiplicity, suppCap, cycleDays];

% Create the GUI window.
f = uifigure('Name','Element Selector','Position',[300 300 980 650]);

% Create a table that lets the user include/exclude elements, set
% multiplicities, and edit suppression parameters.
t = uitable(f, ...
    'Data', cellData, ...
    'ColumnEditable', [false true true true true], ...
    'ColumnFormat', {'char', 'logical', 'numeric', 'numeric', 'numeric'}, ...
    'ColumnName', {'Element','Include','Multiplicity','Suppress (acres/use)','Cycle (days)'}, ...
    'Position', [10 140 960 500]);

% Scenario choices shown in the dropdown menu.
scenarioNames = {'(Custom)', 'Butte County', 'Etosha National Park', 'US/Canadian Wildfires'};

% Create the dropdown menu used to choose a scenario preset.
dd = uidropdown(f, ...
    'Items', scenarioNames, ...
    'Value', '(Custom)', ...
    'Position', [10 95 240 30]);

% Button that applies the selected scenario preset to the GUI table.
uibutton(f, 'Text', 'Apply Scenario', ...
    'Position', [260 95 150 30], ...
    'ButtonPushedFcn', @(btn,event) applyScenarioPreset(dd, t, scenarioPresets));

% Button that resumes the script after the user finishes editing the GUI.
uibutton(f, 'Text', 'Proceed', ...
    'Position', [810 20 160 45], ...
    'ButtonPushedFcn', @(btn,event) uiresume(f));

% Pause script execution until the user clicks Proceed.
uiwait(f);

% Read the edited table data and selected scenario from the GUI.
updatedData = t.Data;
selectedScenario = string(dd.Value);

% Close the GUI after collecting the user selections.
close(f);

% Store the selected scenario in the performance configuration structure so
% downstream functions know which case is being analyzed.
perfCfg.selectedScenario = selectedScenario;

% Assign scenario-specific performance and STK settings.
switch char(selectedScenario)

    case 'Butte County'
        % Butte County / Camp Fire style scenario.
        perfCfg.scenarioName = "Butte County";
        perfOutSheet         = 'ButteCounty';

        % Ignition location and map zoom.
        perfCfg.ignLat   = 39.8134;
        perfCfg.ignLon   = -121.4347;
        perfCfg.centerLat = NaN;
        perfCfg.centerLon = NaN;
        perfCfg.zoom0    = 10;

        % Output files for this scenario.
        perfCfg.outOverlay = "aligned_overlay.png";
        perfCfg.outMask    = "perimeter_mask_warped.png";
        perfCfg.outCSV     = "butte_perimeter_latlon.csv";
        perfCfg.outKML     = "butte_perimeter.kml";

        % Registration and fire-growth assumptions.
        perfCfg.minInliersAccept = 20;
        perfCfg.dayPerimeter     = 3.0;
        perfCfg.naturalHalfLifeDays = 12;

        % STK settings for observation-window analysis.
        stkStartStr   = '9 Oct 2023 14:10:00.000';
        stkStopStr    = '10 Oct 2023 14:10:00.000';
        stkFireLat    = 38.0;
        stkFireLon    = -122.5;
        stkFireAlt_km = 0;
        stkMaxEO      = 8;

    case 'Etosha National Park'
        % Etosha National Park wildfire scenario.
        perfCfg.scenarioName = "Etosha National Park";
        perfOutSheet         = 'Etosha';

        % Ignition location, map center, and zoom. The map center differs
        % from ignition because the screenshot/map region may need to cover a
        % broader area.
        perfCfg.ignLat    = -19.2612; 
        perfCfg.ignLon    = 14.4758;
        perfCfg.centerLat = -18.95;
        perfCfg.centerLon = 16.15;
        perfCfg.zoom0     = 8;

        % Larger map size for this scenario.
        perfCfg.mapW     = 1280;
        perfCfg.mapH     = 1280;
        perfCfg.scale    = 2;

        % Output files for Etosha.
        perfCfg.outOverlay = "etosha_overlay_preview.png";
        perfCfg.outMask    = "etosha_mask_warp.png";
        perfCfg.outCSV     = "etosha_burnscar_latlon.csv";
        perfCfg.outKML     = "etosha_burnscar.kml";

        % Registration and fire-growth assumptions.
        perfCfg.minInliersAccept    = 20;
        perfCfg.dayPerimeter        = 8;
        perfCfg.naturalHalfLifeDays = 2;

        % STK settings for the Etosha observation analysis.
        stkStartStr   = '22 Sep 2025 00:00:00.000';
        stkStopStr    = '30 Sep 2025 23:59:59.000';
        stkFireLat    = perfCfg.ignLat;
        stkFireLon    = perfCfg.ignLon;
        stkFireAlt_km = 0;
        stkMaxEO      = 4;

    case 'US/Canadian Wildfires'
        % Representative Canada 2023 wildfire scenario.
        perfCfg.scenarioName = "US/Canadian Wildfires";
        perfOutSheet         = 'USCanadianWildfires';

        % Representative ignition and map center coordinates.
        perfCfg.ignLat   = 43.669124;
        perfCfg.ignLon   = -65.355936;
        perfCfg.centerLat = 43.669124;
        perfCfg.centerLon = -65.355936;
        perfCfg.zoom0    = 10;

        % Larger map size for the Canada case.
        perfCfg.mapW     = 1280;
        perfCfg.mapH     = 1280;
        perfCfg.scale    = 2;

        % Output files for this scenario.
        perfCfg.outOverlay = "canada_overlay_preview.png";
        perfCfg.outMask    = "canada_perimeter_mask.png";
        perfCfg.outCSV     = "canada_perimeter_latlon.csv";
        perfCfg.outKML     = "canada_perimeter.kml";

        % Registration and fire-growth assumptions.
        perfCfg.minInliersAccept = 13;
        perfCfg.dayPerimeter     = 11;
        perfCfg.naturalHalfLifeDays = 12;

        % STK settings for the US/Canada observation analysis.
        stkStartStr   = '27 May 2023 00:00:00.000';
        stkStopStr    = '21 Jun 2023 23:59:59.000';
        stkFireLat    = perfCfg.ignLat; 
        stkFireLon    = perfCfg.ignLon;
        stkFireAlt_km = 0;
        stkMaxEO      = 8;

    otherwise
        % Custom scenario mode. The user is responsible for supplying or
        % editing configuration values elsewhere.
        perfCfg.scenarioName = "Custom";
        perfOutSheet         = 'CustomScenario';
        warning('Custom scenario selected. Performance config values were not auto-assigned.');
end

% Create a scenario-specific STK observation cache filename. Special
% characters are replaced with underscores so the filename is safe.
stkObsCacheFile = sprintf('stk_obs_cache_%s.mat', regexprep(char(selectedScenario), '[^a-zA-Z0-9]', '_'));
%% === STEP 2.5: Plot hierarchy (Toggled) ===
% If enabled, this section creates a hierarchy plot showing how the selected
% scenario elements are organized across structural, functional, and
% organizational categories.
if doPlotHierarchy

    % Convert the GUI output into a table so the selected values can be
    % referenced by column name.
    updatedTable = cell2table(updatedData, ...
        'VariableNames', {'Element', 'Include', 'Multiplicity', 'Suppress_val', 'Cycle_days'});

    % Find only the elements that the user chose to include.
    includedIdx = find(updatedTable.Include);

    % Clean the included element names so string matching is consistent.
    scenarioNames = string(updatedTable.Element(includedIdx));
    scenarioNames = clean_string(scenarioNames);

    % Build a map from element name to multiplicity for the included
    % scenario elements.
    multVals = updatedTable.Multiplicity(includedIdx);
    multMapScenario = containers.Map(cellstr(scenarioNames), double(multVals));

    % Define organizational elements used in the hierarchy plot.
    orgList = clean_string([ ...
        "Federal Emergency Management Agency"
        "National Interagency Fire Center"
        "US Forest Service"
        "Bureau Of Land Management (BLM)"
        "National Park Service (NPS)"
        "US Fish & Wildlife Services (USFWS)"
        "Bureau Of Indian Affairs (BIA)"
        "US Department of Defense (DOD)"
        "Military Organizations (US National Guard/DOD)"
        "Local Fire Departments"
        "Volunteer Firefighting Organizations"
        "Private Aircraft Operators"
        "National Weather Service (NWS)"
        "National Oceanic & Atmospheric Admin (NOAA)"
        "FAA"
        "U.S. Federal Government"
        "State Governors'' Offices"
    ]);

    % Define functional elements used in the hierarchy plot.
    funcList = clean_string([ ...
        "Deploy Air Assets"
        "Lead Tankers"
        "Supervise Air Attacks (AAGs)"
        "Drop Water"
        "Drop Fire Retardant"
        "Perform Post-Drop Assessment"
        "Dispatch To Reloading Base"
        "Deploy Ground Assets"
        "Establish Containment Lines"
        "Spill Water from Ground Assets"
        "Tactically Monitor Fires"
        "Predict New Fires"
        "Detect Fires"
        "Visually Confirm Fires"
        "Predict Fire Paths/Behavior"
        "Strategically Monitor Fires"
        "Gather Real Time Data from Assets"
        "Build Real Time Situational Awareness"
        "Coordinate Air & Ground Resources"
        "Dynamically Allocate Resources"
        "Issue Commands to Assets"
        "Communicate to Resources"
        "Maintain Communication Among Assets"
        "Maintain Communication Between Assets and C3"
        "Deploy First Response Ground Assets"
        "Deploy Smokejumpers"
        "Activate MAFFS"
        "Refuel Airborne Assets"
        "Provide MRO for Assets"
        "Refill Water and Fire Retardants"
        "Provide Logistic Support to Crews"
    ]);

    % Define structural elements used in the hierarchy plot.
    structList = clean_string([ ...
        "Very Large Air Tankers"
        "Large Air Tankers"
        "Single Engine Airtankers"
        "Water Scoopers"
        "Military Airborne Firefighting System"
        "Helicopters Type I"
        "Helicopters Type II"
        "Helicopters Type III"
        "Tactical Lead Planes"
        "Air Attack Group Supervisor (AAGS)"
        "Smokejumper Aircraft"
        "Tactical UAS"
        "HAPS"
        "EO Satellites (OroraTech)"
        "Weather Satellites (GOES-16/GOES-18)"
        "Comms Satellites (Iridium)"
        "Satellite Imagery Systems (VIIRS Pipeline)"
        "Fire Engines"
        "Airbase Support Systems"
        "C3 Systems"
    ]);

    % Generate the hierarchy plot using the selected scenario elements, the
    % original DSM, and the category lists defined above.
    plotHierarchyFromDSMCell( ...
        scenarioNames, multMapScenario, ...
        elements, DSM_data, ...
        orgList, funcList, structList, ...
        "Scenario Hierarchy");
end

%% === STEP 3: Expand Elements (eta + suppression + cycle_days) by Multiplicity ===
% Convert the GUI output into a table again for the main DSM expansion.
updatedTable = cell2table(updatedData, ...
    'VariableNames', {'Element', 'Include', 'Multiplicity', 'Suppress_val', 'Cycle_days'});

% Identify which original DSM elements are included in the selected scenario.
includedIdx = find(updatedTable.Include);

% Pull multiplicity values for all elements.
multiplicities = updatedTable.Multiplicity;

% Initialize expanded lists. These grow as each included element is
% replicated according to its multiplicity.
expandedElements  = {};
expandedEta       = [];
expandedSupp      = [];
expandedCycleDays = [];
expansionMap      = [];

% Loop through each included original element.
for i = 1:length(includedIdx)

    % Original row/column index in the unexpanded DSM.
    origIdx  = includedIdx(i);

    % Number of copies to create for this element.
    m        = multiplicities(origIdx);

    % Original element name.
    baseName = updatedTable.Element{origIdx};

    % Suppression capability and cycle time associated with this element.
    sCap     = updatedTable.Suppress_val(origIdx);
    cDays    = updatedTable.Cycle_days(origIdx);

    % Create m copies of this element in the expanded architecture.
    for j = 1:m
        expandedElements{end+1,1}  = sprintf('%s', baseName);
        expansionMap(end+1,1)      = origIdx;
        expandedEta(end+1,1)       = eta_orig(origIdx);
        expandedSupp(end+1,1)      = sCap;
        expandedCycleDays(end+1,1) = cDays;
    end
end

% Number of elements after multiplicity expansion.
N = length(expandedElements);

% Initialize the expanded DSM.
expandedDSM = cell(N);

%% === STEP 4: Identify All Unique Interface Characters Used ===
% This section finds every unique interface type character used anywhere in
% the original DSM.
allLetters = [];

% Loop through every cell in the original DSM.
for i = 1:numElems
    for j = 1:numElems
        val = DSM_data{i,j};

        % If the cell contains text, append its characters to the running
        % interface character list.
        if ischar(val) || isstring(val)
            allLetters = [allLetters, char(val)];
        end
    end
end

% Convert to a column vector.
allLetters = allLetters(:);

% Keep only visible/printable characters. This removes blanks and other
% non-interface artifacts.
allLetters = allLetters(isstrprop(allLetters, 'graphic'));

% Preserve the first-seen order of unique interface characters.
interfaceChars = unique(allLetters, 'stable');

% Number of unique interface types.
nInterfaces = numel(interfaceChars);

%% === STEP 5: Expand DSM and Count Interfaces ===
% interfaceCounts stores how many times each interface character appears in
% each expanded DSM row.
interfaceCounts = zeros(N, nInterfaces);

% Loop through each row and column of the expanded DSM.
for row = 1:N
    for col = 1:N

        % Map the expanded row/column back to the original DSM row/column.
        origRow = expansionMap(row);
        origCol = expansionMap(col);

        % Copy the original DSM entry into the expanded DSM location.
        entry   = DSM_data{origRow, origCol};
        expandedDSM{row, col} = entry;

        % Count each interface character appearing in this DSM entry.
        if ischar(entry) || isstring(entry)
            entryStr = char(entry);

            for k = 1:nInterfaces
                c = char(interfaceChars(k));
                interfaceCounts(row, k) = interfaceCounts(row, k) + count(entryStr, c);
            end
        end
    end
end

%% === STEP 6: Write Expanded DSM Matrix to Excel ===
% Build a labeled DSM matrix with element names as both row and column
% headers.
headerRow   = [{''}, expandedElements'];
dataRows    = [expandedElements, expandedDSM];
labeledDSM  = [headerRow; dataRows];

% Replace MATLAB missing values with empty strings so Excel output is clean.
for i = 1:size(labeledDSM, 1)
    for j = 1:size(labeledDSM, 2)
        if ismissing(labeledDSM{i,j})
            labeledDSM{i,j} = "";
        end
    end
end

% Write the expanded DSM to Excel.
writecell(labeledDSM, outputDSM);
disp('Expanded DSM matrix written to Excel.');

%% === STEP 7: Write Interface Count Table (with eta + suppression + cycle_days) ===
% Convert interface characters into valid MATLAB table variable names.
interfaceNames = cellstr(num2cell(interfaceChars(:)));

% Create a table where each row is an expanded element and each interface
% column stores the count of that interface type.
T = array2table(interfaceCounts, ...
    'VariableNames', matlab.lang.makeValidName(interfaceNames));

% Add expanded element names to the front of the table.
T = addvars(T, expandedElements, 'Before', 1, 'NewVariableNames', {'Element'});

% Add eta values for each expanded element.
T = addvars(T, expandedEta(:),  'After', 'Element', 'NewVariableNames', {'eta'});

% Add suppression capability for each expanded element.
T = addvars(T, expandedSupp(:), 'After', 'eta', 'NewVariableNames', {'suppress_val'});

% Add suppression cycle time for each expanded element.
T = addvars(T, expandedCycleDays(:), 'After', 'suppress_val', 'NewVariableNames', {'cycle_days'});

% Clear the old output sheet before writing the new table.
try
    [~, ~, oldRaw] = xlsread(outputCount, outputSheet);
    numOldRows     = size(oldRaw, 1);
    numOldCols     = size(oldRaw, 2);
    lastCol        = excelColumn(numOldCols);
    clearRange     = sprintf('A1:%s%d', lastCol, numOldRows);

    writecell(repmat({''}, numOldRows, numOldCols), ...
        outputCount, 'Sheet', outputSheet, 'Range', clearRange);
catch
    warning('Could not clear old output sheet.');
end

% Write the updated interface count table to Excel.
writetable(T, outputCount, 'Sheet', outputSheet, 'WriteRowNames', false);
disp('Interface count table written to Excel (with eta + suppression + cycle_days).');

%% === STEP 7.5: Compute Complexity Before Performance Model ===
% Compute the architecture complexity after the DSM has been expanded and
% the interface count table has been written.
fprintf('\n=== Complexity Calculation ===\n');

% Run the complexity script. This script reads the interface count workbook
% and computes total Sinha-style complexity using C1, C2, and C3.
sinha_complexity;

% Store the final complexity value in a named variable for later use.
architectureComplexity = total_complexity;

% Print the architecture complexity to the command window.
fprintf('Architecture complexity = %.4f\n', architectureComplexity);

%% === STEP 8: Call performance model with DSM-expanded resources ===
% Run the wildfire performance model using the expanded architecture.
if doRunPerformance

    % Create a resources structure that connects the expanded DSM architecture
    % to the performance model.
    resources = struct();

    % Expanded element names and properties.
    resources.expandedElements  = string(expandedElements);
    resources.expandedEta       = expandedEta(:);
    resources.expandedSuppVal   = expandedSupp(:);
    resources.expandedCycleDays = expandedCycleDays(:);

    % Interface information from the expanded DSM.
    resources.interfaceChars    = interfaceChars(:);
    resources.interfaceCounts   = interfaceCounts;

    % Aggregate suppression capacity. The raw sum treats all suppression
    % assets equally, while the eta-weighted sum scales each suppression
    % value by its eta factor.
    resources.totalSupp_raw = nansum(resources.expandedSuppVal);
    resources.totalSupp_eta = nansum(resources.expandedSuppVal .* max(resources.expandedEta,0));

    % Print a summary of the architecture-to-performance link.
    fprintf('\n=== DSM -> Performance Link ===\n');
    fprintf('Expanded N = %d\n', N);
    fprintf('Total suppression (raw sum) = %.4f\n', resources.totalSupp_raw);
    fprintf('Total suppression (eta-weighted sum) = %.4f\n', resources.totalSupp_eta);

    % ---------------- STK observation metrics ----------------
    % Initialize observation metrics as NaN. These are updated if STK
    % observation analysis is enabled.
    obs = struct();
    obs.EO_MinObsGap_hr = NaN;
    obs.EO_MaxObsGap_hr = NaN;
    obs.Weather_MinObsGap_hr = NaN;
    obs.AllSat_MinObsGap_hr = NaN;
    obs.AllSat_MaxObsGap_hr = NaN;

    % Compute or load STK observation metrics.
    if doRunSTKObs

        % If a scenario-specific STK cache already exists, load it instead of
        % rebuilding the STK observation windows.
        if isfile(stkObsCacheFile)
            Sobs = load(stkObsCacheFile, 'stkObs');
            stkObs = Sobs.stkObs;
            fprintf('Loaded STK observation cache from %s\n', stkObsCacheFile);

        % Otherwise, build the STK cache and save it for future runs.
        else
            fprintf('Building STK observation cache...\n');

            stkObs = build_stk_observation_cache( ...
                stkStartStr, stkStopStr, ...
                stkFireLat, stkFireLon, stkFireAlt_km, ...
                stkMaxEO);

            save(stkObsCacheFile, 'stkObs', '-v7.3');
            fprintf('Saved STK observation cache to %s\n', stkObsCacheFile);
        end

        % Convert the STK access data into observation gap metrics for the
        % selected architecture.
        obs = compute_obs_metrics_from_resources(resources, stkObs);

        % Print the observation gap summary.
        fprintf(['Single-case observation gaps [hr] | ', ...
                 'EO(min,max)=(%s,%s) | Weather=%s | All(min,max)=(%s,%s)\n'], ...
            fmtGap(obs.EO_MinObsGap_hr), ...
            fmtGap(obs.EO_MaxObsGap_hr), ...
            fmtGap(obs.Weather_MinObsGap_hr), ...
            fmtGap(obs.AllSat_MinObsGap_hr), ...
            fmtGap(obs.AllSat_MaxObsGap_hr));
    end

    % ---------------- Build detection delay cases ----------------
    % Combine manual delay cases with STK-derived observation gap delays.
    if doDelaySweep

        % User-defined/manual delay cases.
        manualDelayDays = perfCfg.detectionDelayDaysVec(:);

        % STK-derived delays converted from hours to days.
        stkDelayDays = [
            obs.EO_MinObsGap_hr      / 24
            obs.EO_MaxObsGap_hr      / 24
            obs.Weather_MinObsGap_hr / 24
            obs.AllSat_MinObsGap_hr  / 24
            obs.AllSat_MaxObsGap_hr  / 24
        ];

        % Keep only valid nonnegative STK delay values.
        stkDelayDays = stkDelayDays(isfinite(stkDelayDays) & stkDelayDays >= 0);

        % Merge manual and STK-derived delays, include zero, and sort them.
        delayDaysVec = unique([0; manualDelayDays; stkDelayDays], 'sorted');
    else

        % If delay sweeping is disabled, run only the no-delay case.
        delayDaysVec = 0;
    end

    % Print delay cases in hours for readability.
    fprintf('\nUsing detection delay cases [hr]:\n');
    disp(24 * delayDaysVec.');

    % ---------------- One nominal/base run with normal figures ----------------
    % Run the full performance model once. This produces the nominal fire
    % growth curve and base burned area used by later fast-mode delay cases.
    perfNominal = struct();

    if doNominalFigureRun

        % Full nominal run with figures enabled.
        cfgNom = perfCfg;
        cfgNom.fastMode = false;
        cfgNom.detectionDelayDays = 0;
        cfgNom.doFigures = true;
        cfgNom.saveGif   = false;

        fprintf('\n--- Running nominal/base case with normal figures ---\n');
        perfNominal = wildfire_performance_model(cfgNom, resources);

    else

        % Full nominal run with figures disabled.
        cfgNom = perfCfg;
        cfgNom.fastMode = false;
        cfgNom.detectionDelayDays = 0;
        cfgNom.doFigures = false;
        cfgNom.saveGif   = false;

        fprintf('\n--- Running nominal/base case silently to get A0 ---\n');
        perfNominal = wildfire_performance_model(cfgNom, resources);
    end

    % Confirm that the nominal run returned a valid perimeter-day burned area.
    if ~isfield(perfNominal,'A0_perimeterDay_acres') || isnan(perfNominal.A0_perimeterDay_acres) || perfNominal.A0_perimeterDay_acres <= 0
        error('DSMParseV3:InvalidNominalA0', ...
            'Nominal run did not return a valid A0_perimeterDay_acres for delay sweep.');
    end

    % Store the nominal perimeter-day burned area for fast-mode delay runs.
    A0_base_for_delay = perfNominal.A0_perimeterDay_acres;

    % Store the nominal delay slope if the performance model computed one.
    delaySlopeBase = NaN;
    if isfield(perfNominal,'delaySlopeAcresPerDay')
        delaySlopeBase = perfNominal.delaySlopeAcresPerDay;
    end

    % Store the nominal growth curve so fast mode can reuse it.
    nominalGrowth_tDays = [];
    nominalGrowth_areaAcres = [];

    if isfield(perfNominal,'nominalGrowth_tDays')
        nominalGrowth_tDays = perfNominal.nominalGrowth_tDays;
    end
    if isfield(perfNominal,'nominalGrowth_areaAcres')
        nominalGrowth_areaAcres = perfNominal.nominalGrowth_areaAcres;
    end

    % ---------------- Silent delay sweep (FAST MODE) ----------------
    % Run each delay case in fast mode. This avoids repeating screenshot
    % selection, image registration, map alignment, and animation.
    nDelay = numel(delayDaysVec);
    perfRuns = cell(nDelay,1);
    summaryRows = [];

    for k = 1:nDelay

        % Start from the same base performance configuration.
        cfgThis = perfCfg;

        % Enable fast mode and pass in nominal fire-growth information.
        cfgThis.fastMode = true;
        cfgThis.A0_override_acres = A0_base_for_delay;
        cfgThis.A0_nominal_override_acres = A0_base_for_delay;
        cfgThis.nominalGrowth_tDays = nominalGrowth_tDays;
        cfgThis.nominalGrowth_areaAcres = nominalGrowth_areaAcres;

        % Apply the current delay case.
        cfgThis.detectionDelayDays = delayDaysVec(k);

        % Disable figures, GIFs, and screenshot selection for delay cases.
        cfgThis.doFigures = false;
        cfgThis.saveGif   = false;
        cfgThis.useGUIForScreenshot = false;
        cfgThis.snapFile = "";

        % Reuse the nominal delay slope if available.
        if ~isnan(delaySlopeBase)
            cfgThis.delaySlopeAcresPerDay = delaySlopeBase;
        end

        % Print progress for the current delay case.
        fprintf('\n--- Running delay case %d/%d: %.3f days (%.1f hr) [FAST MODE] ---\n', ...
            k, nDelay, delayDaysVec(k), 24*delayDaysVec(k));

        % Run the performance model for this delay case.
        perfRuns{k} = wildfire_performance_model(cfgThis, resources);

        % Build one summary row for this delay case.
        S = struct();
        S.timestamp                  = string(datetime('now'));
        S.delayDays                  = delayDaysVec(k);
        S.delayHours                 = 24*delayDaysVec(k);
        S.expandedN                  = N;
        S.totalSupp_raw              = resources.totalSupp_raw;
        S.totalSupp_eta              = resources.totalSupp_eta;

        % Copy selected performance outputs into the summary row. Each field
        % is checked before access so the table can still be written if a
        % field is missing.
        if isfield(perfRuns{k},'targetAcres'),                  S.targetAcres = perfRuns{k}.targetAcres; else, S.targetAcres = NaN; end
        if isfield(perfRuns{k},'areaEndAcres'),                 S.areaEndAcres = perfRuns{k}.areaEndAcres; else, S.areaEndAcres = NaN; end
        if isfield(perfRuns{k},'daysTotal'),                    S.daysTotal = perfRuns{k}.daysTotal; else, S.daysTotal = NaN; end
        if isfield(perfRuns{k},'containedDay'),                 S.containedDay = perfRuns{k}.containedDay; else, S.containedDay = NaN; end
        if isfield(perfRuns{k},'resolvedDayAbs'),               S.resolvedDayAbs = perfRuns{k}.resolvedDayAbs; else, S.resolvedDayAbs = NaN; end
        if isfield(perfRuns{k},'resolvedDaysAfterPerimeter'),   S.resolvedDaysAfterPerimeter = perfRuns{k}.resolvedDaysAfterPerimeter; else, S.resolvedDaysAfterPerimeter = NaN; end
        if isfield(perfRuns{k},'AUC_total_acreDays'),           S.AUC_total_acreDays = perfRuns{k}.AUC_total_acreDays; else, S.AUC_total_acreDays = NaN; end
        if isfield(perfRuns{k},'CO2_baseline_MMT'),             S.CO2_baseline_MMT = perfRuns{k}.CO2_baseline_MMT; else, S.CO2_baseline_MMT = NaN; end
        if isfield(perfRuns{k},'CO2_est_millionMetricTons'),    S.CO2_est_millionMetricTons = perfRuns{k}.CO2_est_millionMetricTons; else, S.CO2_est_millionMetricTons = NaN; end
        if isfield(perfRuns{k},'A0_perimeterDay_acres'),        S.A0_perimeterDay_acres = perfRuns{k}.A0_perimeterDay_acres; else, S.A0_perimeterDay_acres = NaN; end
        if isfield(perfRuns{k},'A0_delayed_acres'),             S.A0_delayed_acres = perfRuns{k}.A0_delayed_acres; else, S.A0_delayed_acres = NaN; end

        % Add STK observation metrics to every summary row.
        S.EO_MinObsGap_hr      = obs.EO_MinObsGap_hr;
        S.EO_MaxObsGap_hr      = obs.EO_MaxObsGap_hr;
        S.Weather_MinObsGap_hr = obs.Weather_MinObsGap_hr;
        S.AllSat_MinObsGap_hr  = obs.AllSat_MinObsGap_hr;
        S.AllSat_MaxObsGap_hr  = obs.AllSat_MaxObsGap_hr;

        % Convert the first summary row into a table. Later rows are appended
        % to the same table.
        if k == 1
            summaryRows = struct2table(S);
        else
            summaryRows = [summaryRows; struct2table(S)];
        end
    end

    % ---------------- Combined delay comparison plot ----------------
    % Plot all delay cases on the same figure so the effect of delayed
    % detection/coordination can be compared directly.
    if plotDelayComparison && nDelay >= 1
        figure('Name','Burn Area vs Time - Detection Delay Comparison','Color','w');
        hold on; grid on;

        % Assign one color to each delay case.
        cmap = lines(nDelay);
        legText = strings(nDelay,1);

        % Plot each delay case if it returned a total burn-area trajectory.
        for k = 1:nDelay
            if isfield(perfRuns{k},'tAbsDays_total') && isfield(perfRuns{k},'areaAcres_total') ...
                    && ~isempty(perfRuns{k}.tAbsDays_total) && ~isempty(perfRuns{k}.areaAcres_total)

                plot(perfRuns{k}.tAbsDays_total, perfRuns{k}.areaAcres_total, ...
                    'LineWidth', 2.2, 'Color', cmap(k,:));

                legText(k) = sprintf('Delay = %.1f hr | A_0 = %.0f ac', ...
                    24*delayDaysVec(k), perfRuns{k}.A0_delayed_acres);
            end
        end

        % Label the delay comparison figure.
        xlabel('Time [Days]');
        ylabel('Burn Area [Acres]');
        title('Burn Area vs. Time for Different Detection Delays');
        legend(legText, 'Location','northeastoutside');

        % Add a vertical line marking the nominal perimeter day.
        xline(perfCfg.dayPerimeter, '--k', sprintf('Day %.2f perimeter', perfCfg.dayPerimeter), ...
            'LabelOrientation','aligned', ...
            'LabelVerticalAlignment','bottom');
    end

    % Write the delay-sweep performance summary to Excel.
    try
        writetable(summaryRows, perfOutXlsx, 'Sheet', perfOutSheet, 'WriteRowNames', false);
        disp("Performance summary written to: " + perfOutXlsx);
    catch ME
        warning("Could not write performance output Excel. MATLAB says:\n%s", ME.message);
    end
end    
    %% === Helper: Convert Integer to Excel Column Letters ===
function col = excelColumn(n)
    % Convert an Excel column number into its letter label.
    % Example: 1 -> A, 26 -> Z, 27 -> AA.

    col = '';

    while n > 0
        r = rem(n-1,26);
        col = [char(r + 'A'), col];
        n = floor((n - 1) / 26);
    end
end

%% === Helper: Robust conversion to double ===
function x = robustToDouble(v)
    % Convert different MATLAB/Excel cell value types into a numeric double.
    % This is useful because readcell may return numbers, strings, characters,
    % logicals, blanks, or missing values depending on the Excel cell.

    x = nan;

    % Direct numeric scalar case.
    if isnumeric(v) && isscalar(v) && ~isnan(v)
        x = v;

    % Logical values are converted to 0 or 1.
    elseif islogical(v) && isscalar(v)
        x = double(v);

    % Text values are trimmed and converted with str2double.
    elseif ischar(v) || isstring(v)
        vv = str2double(strtrim(string(v)));
        if ~isnan(vv)
            x = vv;
        end
    end
end

%% === Helper: clean DSM names consistently ===
function s = clean_string(x)
    % Clean element names so comparisons are more reliable.
    % This removes leading/trailing spaces and nonbreaking spaces.

    s = strtrim(erase(string(x), char(160)));
end

%% === Scenario Apply callback: ONLY sets Include + Multiplicity ===
function applyScenarioPreset(dd, t, scenarioPresets)
    % Callback used by the GUI's Apply Scenario button.
    % It updates the Include and Multiplicity columns based on the selected
    % scenario preset.

    choice = dd.Value;
    if isstring(choice), choice = char(choice); end

    % Select the correct scenario multiplicity map.
    switch choice
        case 'Butte County'
            presetMap_mult = scenarioPresets.ButteCounty_mult;
        case 'Etosha National Park'
            presetMap_mult = scenarioPresets.Etosha_mult;
        case 'US/Canadian Wildfires'
            presetMap_mult = scenarioPresets.USCanadianWildfires_mult;
        otherwise
            return;
    end

    % Pull current GUI table data.
    D = t.Data;

    % Loop through every element in the table. If the element exists in the
    % preset, include it and apply the preset multiplicity. Otherwise,
    % exclude it and reset multiplicity to one.
    for irow = 1:size(D,1)
        name = D{irow,1};
        if isstring(name), name = char(name); end

        if isKey(presetMap_mult, name)
            D{irow,2} = true;
            D{irow,3} = presetMap_mult(name);
        else
            D{irow,2} = false;
            D{irow,3} = 1;
        end
    end

    % Push the updated data back into the GUI table.
    t.Data = D;
end

%% === STK helper: compute observation metrics from resources ===
function obs = compute_obs_metrics_from_resources(resources, stkObs)
    % Compute satellite observation gap metrics for the selected architecture.
    %
    % This function checks how many EO and weather satellites are included in
    % the expanded resources structure, pulls their cached access intervals,
    % merges overlapping intervals, and computes the minimum and maximum gaps
    % between observations.

    % Initialize outputs as NaN. These values remain NaN if no valid
    % observation intervals are available.
    obs = struct();
    obs.EO_MinObsGap_hr = NaN;
    obs.EO_MaxObsGap_hr = NaN;
    obs.Weather_MinObsGap_hr = NaN;
    obs.AllSat_MinObsGap_hr = NaN;
    obs.AllSat_MaxObsGap_hr = NaN;

    % Count included EO and weather satellites from the expanded architecture.
    nEO = get_resource_asset_count(resources, 'EO Satellites (OroraTech)');
    nW  = get_resource_asset_count(resources, 'Weather Satellites (GOES-16/GOES-18)');

    % Limit the requested satellite count to the number available in the STK
    % cache.
    nEO = max(0, min(nEO, numel(stkObs.eoNames)));
    nW  = max(0, min(nW,  numel(stkObs.weatherNames)));

    % Select the first nEO EO satellites and first nW weather satellites from
    % the STK cache.
    eoNames = stkObs.eoNames(1:nEO);
    wNames  = stkObs.weatherNames(1:nW);

    % Collect observation intervals for each satellite group.
    eoIntervals  = collect_intervals_from_cache(stkObs, eoNames);
    wIntervals   = collect_intervals_from_cache(stkObs, wNames);
    allIntervals = [eoIntervals; wIntervals];

    % Merge overlapping intervals so continuous coverage is treated as one
    % observation window.
    eoMerged  = merge_time_intervals(eoIntervals);
    wMerged   = merge_time_intervals(wIntervals);
    allMerged = merge_time_intervals(allIntervals);

    % Compute observation gap statistics in hours.
    [obs.EO_MinObsGap_hr, obs.EO_MaxObsGap_hr] = observation_gap_stats_hours(eoMerged, stkObs.startStr, stkObs.stopStr);
    [obs.Weather_MinObsGap_hr, ~]              = observation_gap_stats_hours(wMerged,  stkObs.startStr, stkObs.stopStr);
    [obs.AllSat_MinObsGap_hr, obs.AllSat_MaxObsGap_hr] = observation_gap_stats_hours(allMerged, stkObs.startStr, stkObs.stopStr);
end

function n = get_resource_asset_count(resources, assetName)
    % Count how many copies of a named asset appear in the expanded resource
    % list.

    n = 0;

    if isfield(resources, 'expandedElements')
        names = string(resources.expandedElements(:));
        n = sum(strcmp(names, string(assetName)));
    end
end

function intervals = collect_intervals_from_cache(stkObs, satNames)
    % Collect cached STK access intervals for a list of satellite names.

    % Initialize an empty datetime interval array with UTC timezone.
    intervals = NaT(0,2,'TimeZone','UTC');

    % Loop through requested satellites.
    for i = 1:numel(satNames)

        % Convert satellite name to a valid MATLAB field name.
        fld = matlab.lang.makeValidName(char(satNames(i)));

        % If the satellite has cached intervals, append them.
        if isfield(stkObs.intervals, fld)
            A = stkObs.intervals.(fld);
            if ~isempty(A)
                intervals = [intervals; A];
            end
        end
    end
end

function merged = merge_time_intervals(intervals)
    % Merge overlapping time intervals.
    %
    % For example, if one satellite observes from 1:00-1:10 and another
    % observes from 1:05-1:20, this helper merges them into one continuous
    % 1:00-1:20 observation window.

    if isempty(intervals)
        merged = NaT(0,2,'TimeZone','UTC');
        return;
    end

    % Sort intervals by start time.
    intervals = sortrows(intervals, 1);

    % Start the merged list with the first interval.
    merged = intervals(1,:);

    % Step through the remaining intervals.
    for i = 2:size(intervals,1)
        s = intervals(i,1);
        e = intervals(i,2);

        lastE = merged(end,2);

        % If the next interval starts before the current merged interval
        % ends, merge them by extending the end time.
        if s <= lastE
            merged(end,2) = max(lastE, e);

        % Otherwise, start a new merged interval.
        else
            merged = [merged; [s e]];
        end
    end
end

function [gMin, gMax] = observation_gap_stats_hours(mergedIntervals, startStr, stopStr)
    % Compute the minimum and maximum observation gaps between merged access
    % intervals over a full STK scenario time window.

    % Convert STK-style start and stop strings into UTC datetimes.
    tStart = datetime(startStr, 'InputFormat','d MMM yyyy HH:mm:ss.SSS', 'TimeZone','UTC');
    tStop  = datetime(stopStr,  'InputFormat','d MMM yyyy HH:mm:ss.SSS', 'TimeZone','UTC');

    % Initialize outputs.
    gMin = NaN;
    gMax = NaN;

    % If no intervals exist, no observation gap metric can be computed.
    if isempty(mergedIntervals)
        return;
    end

    % Sort the intervals and clip them to the scenario start/stop window.
    mergedIntervals = sortrows(mergedIntervals, 1);
    mergedIntervals(:,1) = max(mergedIntervals(:,1), tStart);
    mergedIntervals(:,2) = min(mergedIntervals(:,2), tStop);

    % Remove intervals that fall completely outside the scenario window.
    keep = mergedIntervals(:,2) >= mergedIntervals(:,1);
    mergedIntervals = mergedIntervals(keep,:);

    if isempty(mergedIntervals)
        return;
    end

    % Store gaps in hours.
    gapsHr = [];

    % Gap from scenario start to the first observation interval.
    g0 = hours(mergedIntervals(1,1) - tStart);
    if g0 > 0
        gapsHr(end+1,1) = g0;
    end

    % Gaps between consecutive observation intervals.
    for k = 1:size(mergedIntervals,1)-1
        gk = hours(mergedIntervals(k+1,1) - mergedIntervals(k,2));
        if gk > 0
            gapsHr(end+1,1) = gk;
        end
    end

    % Gap from the final observation interval to scenario stop.
    gF = hours(tStop - mergedIntervals(end,2));
    if gF > 0
        gapsHr(end+1,1) = gF;
    end

    % If there are no positive gaps, coverage is continuous across the
    % scenario window.
    if isempty(gapsHr)
        gMin = 0;
        gMax = 0;
    else
        gMin = min(gapsHr);
        gMax = max(gapsHr);
    end
end

function s = fmtGap(x)
    % Format observation gap values for command-window printing.

    if isnan(x)
        s = 'NaN';
    elseif x == 0
        s = '0';
    else
        s = sprintf('%.3f', x);
    end
end

%% === Hierarchy plotting helpers ===

function plotHierarchyFromDSMCell(scenarioNames, multMap, allElements, DSM_data, orgList, funcList, structList, figTitle)
    % Plot a simplified hierarchy graph from the DSM.
    %
    % The graph shows selected organizational, functional, and structural
    % elements and draws directed links based on DSM entries. It only plots
    % relationships that follow the intended hierarchy:
    %   Organization -> Function
    %   Function     -> Structure
    %   Organization -> Structure

    % Clean all input names before matching.
    scenarioNames = clean_string(scenarioNames(:));
    orgList       = clean_string(orgList(:));
    funcList      = clean_string(funcList(:));
    structList    = clean_string(structList(:));
    allElements   = clean_string(string(allElements(:)));

    % Match selected scenario element names to the full DSM element list.
    [tf, idx] = ismember(scenarioNames, allElements);

    % Stop if any selected scenario elements are not found in the DSM.
    if any(~tf)
        missing = scenarioNames(~tf);
        error("Hierarchy plot: scenario elements not found in DSM element list:\n%s", strjoin(missing, "\n"));
    end

    % Classify selected elements as organizational, functional, or structural.
    isOrg  = ismember(scenarioNames, orgList);
    isFunc = ismember(scenarioNames, funcList);
    isStr  = ismember(scenarioNames, structList);

    % Warn if any selected elements do not fall into one of the three
    % hierarchy categories.
    unclassified = scenarioNames(~(isOrg|isFunc|isStr));
    if ~isempty(unclassified)
        warning("Hierarchy plot: unclassified elements excluded:\n%s", strjoin(unclassified, "\n"));
    end

    % Keep only classified elements.
    keep = (isOrg|isFunc|isStr);
    scenarioNames = scenarioNames(keep);
    idx           = idx(keep);
    isOrg         = isOrg(keep);
    isFunc        = isFunc(keep);
    isStr         = isStr(keep);

    % Initialize directed graph source and destination lists.
    src = strings(0,1);
    dst = strings(0,1);
    n = numel(scenarioNames);

    % Check DSM relationships between all selected elements.
    for i = 1:n
        for j = 1:n

            % Ignore self-links.
            if i==j, continue; end

            % Read the DSM cell connecting element i to element j.
            entry = DSM_data{idx(i), idx(j)};

            % A nonempty text entry indicates a DSM relationship.
            hasLink = (ischar(entry) && ~isempty(strtrim(entry))) || ...
                      (isstring(entry) && strlength(strtrim(entry))>0);

            if ~hasLink, continue; end

            % Only keep links that align with the hierarchy.
            if isOrg(i) && isFunc(j)
                src(end+1,1) = scenarioNames(i); 
                dst(end+1,1) = scenarioNames(j); 
            elseif isFunc(i) && isStr(j)
                src(end+1,1) = scenarioNames(i); 
                dst(end+1,1) = scenarioNames(j); 
            elseif isOrg(i) && isStr(j)
                src(end+1,1) = scenarioNames(i); 
                dst(end+1,1) = scenarioNames(j); 
            end
        end
    end

    % Create the directed graph from the selected links.
    G = digraph(src, dst);

    % If there are no links, still create a graph containing the selected
    % nodes so the plot is not empty.
    if numnodes(G) == 0
        G = digraph();
        G = addnode(G, cellstr(scenarioNames));
    end

    % Use graph node names as default labels.
    nodeNames  = string(G.Nodes.Name);
    nodeLabels = nodeNames;

    % Add multiplicity labels to nodes where multiplicity is greater than 1.
    for k = 1:numel(nodeNames)
        nm = char(nodeNames(k));
        if ~isempty(multMap) && isKey(multMap, nm)
            m = multMap(nm);
            if m > 1
                nodeLabels(k) = nodeNames(k) + "  x" + string(m);
            end
        end
    end

    % Wrap long labels across multiple lines so the plot stays readable.
    nodeLabelsWrapped = wrapLabels(cellstr(nodeLabels), 14);

    % Separate graph nodes into organization, function, and structure rows.
    orgNodes  = sort(nodeNames(ismember(nodeNames, scenarioNames(isOrg))));
    funcNodes = sort(nodeNames(ismember(nodeNames, scenarioNames(isFunc))));
    strNodes  = sort(nodeNames(ismember(nodeNames, scenarioNames(isStr))));

    % Initialize node positions.
    X = zeros(numnodes(G),1);
    Y = zeros(numnodes(G),1);

    % Place organizations at the top, functions in the middle, and
    % structures at the bottom.
    [Xo, Yo] = assignRow(orgNodes,  2.0, G);
    [Xf, Yf] = assignRow(funcNodes, 1.0, G);
    [Xs, Ys] = assignRow(strNodes,  0.0, G);

    X = X + Xo + Xf + Xs;
    Y = Y + Yo + Yf + Ys;

    % Plot the hierarchy graph.
    figure('Color','w','Name',char(figTitle), 'Position', [80 80 1700 900]);
    plot(G, 'XData', X, 'YData', Y, 'NodeLabel', {}, 'ArrowSize', 8, 'LineWidth', 1.0);
    title(figTitle);
    axis off;

    % Manually place wrapped labels next to nodes.
    hold on;
    dx = 0.006; 
    dy = 0.00;

    for k = 1:numel(nodeLabelsWrapped)
        text(X(k) + dx, Y(k) + dy, nodeLabelsWrapped{k}, ...
            'FontSize', 8, 'Color', [0 0 0], 'Interpreter', 'none', ...
            'HorizontalAlignment', 'left', 'VerticalAlignment', 'middle');
    end

    hold off;
end

function [X, Y] = assignRow(nodeList, yval, G)
    % Assign x/y coordinates to a group of nodes on one horizontal row.

    X = zeros(numnodes(G),1);
    Y = zeros(numnodes(G),1);

    % Return zero vectors if there are no nodes in this category.
    if isempty(nodeList), return; end

    % Spread the nodes evenly across the horizontal axis.
    xs = linspace(0.05, 0.95, numel(nodeList));

    % Assign positions to matching graph nodes.
    for k = 1:numel(nodeList)
        idx = find(string(G.Nodes.Name) == nodeList(k), 1);
        if ~isempty(idx)
            X(idx) = xs(k);
            Y(idx) = yval;
        end
    end
end

function out = wrapLabels(lbls, maxChars)
    % Wrap long node labels onto multiple lines.
    %
    % This keeps labels readable in crowded hierarchy plots.

    out = lbls;

    % Process each label independently.
    for i = 1:numel(lbls)
        s = char(lbls{i});

        % Short labels do not need wrapping.
        if length(s) <= maxChars
            continue;
        end

        % Split the label into words.
        words = strsplit(s, ' ');
        lines = "";
        cur = "";

        % Build lines one word at a time.
        for w = 1:numel(words)
            if strlength(cur) == 0
                trial = string(words{w});
            else
                trial = cur + " " + string(words{w});
            end

            % Add the word to the current line if it fits.
            if strlength(trial) <= maxChars
                cur = trial;

            % Otherwise, start a new line.
            else
                if strlength(lines) == 0
                    lines = cur;
                else
                    lines = lines + newline + cur;
                end
                cur = string(words{w});
            end
        end

        % Add the final line.
        if strlength(cur) > 0
            if strlength(lines) == 0
                lines = cur;
            else
                lines = lines + newline + cur;
            end
        end

        % Store the wrapped label.
        out{i} = char(lines);
    end
end