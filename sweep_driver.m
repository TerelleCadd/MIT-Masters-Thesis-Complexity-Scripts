%% sweep_driver.m
%RUN_ARCHITECTURE_GRID_SWEEP
%
% Overall purpose:
% This script runs a full architecture grid sweep for the wildfire response
% system-of-systems model. It tests many combinations of response assets,
% computes complexity for each architecture, runs the wildfire performance
% model, estimates cost and CO2-related metrics, and saves the results for
% later trade-space analysis.
%
% In plain terms:
% - Pick one wildfire scenario.
% - Generate many possible response architectures.
% - Build each architecture from the DSM/MDM model.
% - Compute complexity, performance, cost, CO2, and observation metrics.
% - Save everything so it can be plotted and compared later.
%
% Main outputs:
% - A checkpoint MAT file that can be used while the sweep is running.
% - A final MAT file containing all sweep results.
% - A CSV summary table for quick analysis outside MATLAB.
% - Optional Excel output if export_now is called.

% Clear the workspace, command window, and any open figures so each sweep starts clean.
clear; clc; close all;

% This section lets the user choose which scenario-specific settings to load.
%% ============ USER SCENARIO SELECTOR ============
% Select the scenario to evaluate. 
% Valid options are: "Butte County", "Etosha National Park", or "US/Canadian Wildfires".
SCENARIO = "Etosha National Park";

% This optional reset section is useful when rerunning a sweep from scratch.
%% ============ RESET TO ITERATION 1 (uncomment to force reset) ============
% if exist('sweep_results_checkpoint.mat','file'), delete('sweep_results_checkpoint.mat'); end
% if exist('sweep_results_final.mat','file'), delete('sweep_results_final.mat'); end
% if exist('sweep_results_summary.csv','file'), delete('sweep_results_summary.csv'); end
% clear build_dsm_config_no_gui

% Save a checkpoint every N iterations so long sweeps can be restarted without losing progress.
checkpointEvery = 25;
% Refresh the live plots every N iterations rather than on every single configuration.
plotEvery = 10;

% Convert the scenario name into a safe filename tag by replacing symbols and spaces with underscores.
scenarioTag = regexprep(lower(char(SCENARIO)), '[^a-z0-9]+', '_');
% Remove any leading or trailing underscores from the generated file tag.
scenarioTag = regexprep(scenarioTag, '^_+|_+$', '');

% Keep Canada/US perturbation outputs separate
if SCENARIO == "US/Canadian Wildfires"
    scenarioTag = scenarioTag + "_usgov";
end

% Build output filenames that are unique to the selected scenario.
outMatCheckpoint = sprintf('sweep_results_checkpoint_%s.mat', scenarioTag);
outMatFinal      = sprintf('sweep_results_final_%s.mat', scenarioTag);
outCsv           = sprintf('sweep_results_summary_%s.csv', scenarioTag);
outXlsxDefault   = sprintf('sweep_results_detailed_%s.xlsx', scenarioTag);

% Set this to true if you want the detailed Excel export to run automatically after the sweep finishes.
AUTO_EXPORT_XLSX_AT_END = false;
outXlsxDefault = sprintf('sweep_results_detailed_%s.xlsx', scenarioTag);

% This optional reset section is useful when rerunning a sweep from scratch.
%% ============ RESET TO ITERATION 1 (uncomment to force reset) ============
if exist(outMatCheckpoint,'file'), delete(outMatCheckpoint); end
if exist(outMatFinal,'file'), delete(outMatFinal); end
if exist(outCsv,'file'), delete(outCsv); end

% This switch controls whether MATLAB figures are updated while the sweep is running.
%% Toggling Live Plots
ENABLE_LIVE_PLOTS = true;

% Load scenario-specific constants such as fire size, perimeter day, and STK cache settings.
%% ============ SCENARIO SETTINGS ============
% Use the helper function at the bottom of this script to build the scenario configuration structure.
scenarioCfg = getScenarioSweepSettings(SCENARIO);

fprintf('Running sweep for scenario: %s\n', scenarioCfg.name);

% Store the baseline burned area used by the fast performance model.
A0_BASE_ACRES = scenarioCfg.A0_BASE_ACRES;

% These options tell the complexity function which workbook, sheets, and range contain C1 and C2 inputs.
%% Complexity options
compOpts = struct();
compOpts.c1_file  = 'Wildfire Response Function Criticality.xlsx';
compOpts.c1_sheet = 'C1 Summary';
compOpts.c2_sheet = 'C2 Interface Weights';
compOpts.c2_range = 'E11:F26';

% Define the asset-count values that will be tested for the selected scenario.
%% Sweep grids
% Initialize the sweep-grid structure before filling it with scenario-specific parameter lists.
sweepGrid = struct();

% Choose the correct sweep ranges based on the selected scenario.
switch scenarioCfg.name
    case "Butte County"
        sweepGrid.VLAT     = [0 1 2];
        sweepGrid.LAT      = [0 2 3];
        sweepGrid.SEAT     = [0 4 5];
        sweepGrid.HeliI    = [0 6 10];
        sweepGrid.HeliII   = [0 8 10];
        sweepGrid.HeliIII  = [0 5 15];
        sweepGrid.EO       = [0 3 8];
        sweepGrid.Weather  = [0 3];
        sweepGrid.Iridium  = 1;
        sweepGrid.FireEng  = [522 622 722];

        % Fixed values are assets or support elements that do not vary in the grid sweep for this scenario.
        fixed = struct();
        fixed.LeadPlanes = 2;
        fixed.Smokejump  = 1;
        fixed.UAS        = 3;
        fixed.VIIRS      = 1;
        fixed.Airbase    = 2;
        fixed.C3         = 1;

    case "Etosha National Park"
        sweepGrid.VLAT     = [0 2];
        sweepGrid.LAT      = [0 1 2];
        sweepGrid.SEAT     = [0 2 3];
        sweepGrid.HeliI    = [0 1 2];
        sweepGrid.HeliII   = [0 2 3];
        sweepGrid.HeliIII  = [0 3 4];
        sweepGrid.EO       = [0 3 8];
        sweepGrid.Weather  = [0 1 2];
        sweepGrid.Iridium  = 1;
        sweepGrid.FireEng  = [80 100 125 150];

        % Fixed values are assets or support elements that do not vary in the grid sweep for this scenario.
        fixed = struct();
        fixed.LeadPlanes = 1;
        fixed.Smokejump  = 0;
        fixed.UAS        = 2;
        fixed.VIIRS      = 1;
        fixed.Airbase    = 1;
        fixed.C3         = 1;

    case "US/Canadian Wildfires"
        sweepGrid.VLAT     = [0 1 2];
        sweepGrid.LAT      = [0 2 4];
        sweepGrid.SEAT     = [0 4 6];
        sweepGrid.HeliI    = [0 6 8];
        sweepGrid.HeliII   = [0 8 12];
        sweepGrid.HeliIII  = [0 10 16];
        sweepGrid.EO       = [0 4 8];
        sweepGrid.Weather  = [0 1];
        sweepGrid.Iridium  = 1;
        sweepGrid.FireEng  = [10 20 30];
        % Local sweep variable used only when generating the Canada/US configuration overrides.
        sweepGrid.USGov = [0 1];

        % Fixed values are assets or support elements that do not vary in the grid sweep for this scenario.
        fixed = struct();
        fixed.LeadPlanes = 3;
        fixed.Smokejump  = 2;
        fixed.UAS        = 4;
        fixed.VIIRS      = 1;
        fixed.Airbase    = 3;
        fixed.C3         = 1;

    otherwise
        error('Unknown scenario: %s', scenarioCfg.name);
end

% Build the full list of configurations to evaluate.
% Keep the saved results matrix structure unchanged.
% For Canada/US only, X carries an extra 11th local variable (USGov),
% but R still stores only the original 10 sweep variables.
% Choose the correct sweep ranges based on the selected scenario.
switch scenarioCfg.name
    case "US/Canadian Wildfires"
        [VLAT, LAT, SEAT, H1, H2, H3, EO, W, IR, FE, USG] = ndgrid( ...
            sweepGrid.VLAT, sweepGrid.LAT, sweepGrid.SEAT, ...
            sweepGrid.HeliI, sweepGrid.HeliII, sweepGrid.HeliIII, ...
            sweepGrid.EO, sweepGrid.Weather, sweepGrid.Iridium, ...
            sweepGrid.FireEng, sweepGrid.USGov);

        X = [VLAT(:), LAT(:), SEAT(:), H1(:), H2(:), H3(:), EO(:), W(:), IR(:), FE(:), USG(:)];

    otherwise
        [VLAT, LAT, SEAT, H1, H2, H3, EO, W, IR, FE] = ndgrid( ...
            sweepGrid.VLAT, sweepGrid.LAT, sweepGrid.SEAT, ...
            sweepGrid.HeliI, sweepGrid.HeliII, sweepGrid.HeliIII, ...
            sweepGrid.EO, sweepGrid.Weather, sweepGrid.Iridium, sweepGrid.FireEng);

        X = [VLAT(:), LAT(:), SEAT(:), H1(:), H2(:), H3(:), EO(:), W(:), IR(:), FE(:)];
end

% Choose the order in which configurations will be processed.
%% ---------------- Sweep ordering ----------------
% Choose the order in which configurations are evaluated: 'forward', 'reverse', or 'random'.
orderMode = 'random';
% Use a fixed random seed so the randomized sweep order is repeatable.
randomSeed = 42;

switch lower(orderMode)
    case 'forward'
    case 'reverse'
        X = flipud(X);
    case 'random'
        rng(randomSeed,'twister');
        perm = randperm(size(X,1));
        X = X(perm,:);
    otherwise
        error('Unknown orderMode: %s', orderMode);
end

% Count how many non-baseline configurations are in the sweep.
N_sweep = size(X,1);
% Add one extra row for the baseline configuration.
N_total = N_sweep + 1;
fprintf("Sweep configs: %d | Total incl baseline: %d\n", N_sweep, N_total);

% Create a signature of the sweep setup so old checkpoints are only reused when they match the current run.
SWEEP_SIGNATURE = string(jsonencode(struct( ...
    'scenario', scenarioCfg.name, ...
    'grid', sweepGrid, ...
    'fixed', fixed, ...
    'orderMode', orderMode, ...
    'randomSeed', randomSeed, ...
    'xWidth', size(X,2), ...
    'delayMethod', 'interp1_per_config_nominal_ref_v1')));

% Preallocate storage for results, error flags, baseline architecture exports, and plotting variables.
%% Results matrix
% R stores all numeric results. Each row is one configuration and each column is one output metric.
R = nan(N_total, 33);

% errFlag records whether a configuration failed.
errFlag = false(N_total,1);
% errMsg stores the error message for failed configurations.
errMsg  = strings(N_total,1);

% These baseline arrays track which master elements are included so the exported configuration table stays aligned.
BASE_ELEM_IDX   = [];
BASE_ELEM_NAMES = string.empty;
M_export        = [];

% This scaling factor converts burn burden in acre-days into an estimated CO2 value.
gamma_MMT_per_acreDay = NaN;
% This array tracks whether each Canada/US configuration has US aid turned on or off for plotting.
USGov_plot = nan(N_total,1);
USGov_plot(1) = 1;

% Load or build the satellite observation cache used to estimate detection-delay metrics.
%% ===================== STK OBSERVATION CACHE =====================
% Set this to false to skip STK-based observation gap metrics.
USE_STK_OBS = true;
stkObs = struct();

if USE_STK_OBS
    stkObsMat = scenarioCfg.stkObsCacheFile;

    % If a cache already exists for this scenario, load it instead of rebuilding the STK case.
    if isfile(stkObsMat)
        Sobs = load(stkObsMat, 'stkObs');
        stkObs = Sobs.stkObs;
        fprintf('Loaded STK observation cache from %s\n', stkObsMat);
    else
        fprintf('Building STK observation cache...\n');
        % If no cache exists, build one using the scenario timing, fire location, and maximum EO satellite count.
        stkObs = build_stk_observation_cache( ...
            scenarioCfg.stkStartStr, ...
            scenarioCfg.stkStopStr, ...
            scenarioCfg.stkFireLat, ...
            scenarioCfg.stkFireLon, ...
            scenarioCfg.stkFireAlt_km, ...
            max(sweepGrid.EO));
        save(stkObsMat, 'stkObs', '-v7.3');
        fprintf('Saved STK observation cache to %s\n', stkObsMat);
    end
end

% Create all live plotting figures and placeholder plot objects before the sweep starts.
%% ===================== LIVE PLOTS =====================
% Only create figures if live plotting is enabled.
if ENABLE_LIVE_PLOTS
    % Create the main live plot for complexity versus resolution time.
    fig = figure('Color','w','Name','Complexity vs Performance');
    ax = axes('Parent',fig);
    hold(ax,'on'); grid(ax,'on');
    xlabel(ax,'Resolution Time [Days]'); ylabel(ax,'Total Complexity');
    title(ax,['Complexity vs Resolution Day - ' char(scenarioCfg.name)]);

    % For the Canada/US case, create separate markers for US aid on and US aid off cases.
    if SCENARIO == "US/Canadian Wildfires"
        hScatterUSOn  = scatter(ax, nan, nan, 12, 'filled', ...
            'MarkerFaceColor',[0 0.4470 0.7410], ...
            'MarkerEdgeColor',[0 0.4470 0.7410]);
        hScatterUSOff = scatter(ax, nan, nan, 12, 'filled', ...
            'MarkerFaceColor','k', ...
            'MarkerEdgeColor','k');
        hPareto  = scatter(ax, nan, nan, 12, 'filled', ...
            'MarkerFaceColor',[0.85 0.33 0.10], ...
            'MarkerEdgeColor','k', ...
            'LineWidth',0.75);
        hParetoLine = plot(ax, nan, nan, '-', ...
            'Color',[0.85 0.33 0.10], ...
            'LineWidth',1.5);
        hBase    = scatter(ax, nan, nan, 40, 'filled', 'r');

        legend(ax, [hPareto, hScatterUSOff, hScatterUSOn, hBase], ...
            {'Pareto','US Off','US On','Baseline'}, ...
            'Location','northwest');
    else
        hScatterUSOn  = scatter(ax, nan, nan, 12, 'filled');
        % This placeholder is unused for non-US/Canada cases, but is kept so updatePlots can use the same inputs.
        hScatterUSOff = scatter(ax, nan, nan, 12, 'filled');
        hPareto  = scatter(ax, nan, nan, 12, 'filled', ...
            'MarkerFaceColor',[0.85 0.33 0.10], ...
            'MarkerEdgeColor','k', ...
            'LineWidth',0.75);
        hParetoLine = plot(ax, nan, nan, '-', ...
            'Color',[0.85 0.33 0.10], ...
            'LineWidth',1.5);
        hBase    = scatter(ax, nan, nan, 40, 'filled', 'r');
    end

    % Create the live plot for complexity versus total cost.
    figC = figure('Color','w','Name','Complexity vs Cost');
    axC = axes('Parent',figC);
    hold(axC,'on'); grid(axC,'on');
    xlabel(axC,'Total Cost [Million USD]'); ylabel(axC,'Total Complexity');
    title(axC,['Complexity vs Total Cost - ' char(scenarioCfg.name)]);

    % For the Canada/US case, create separate markers for US aid on and US aid off cases.
    if SCENARIO == "US/Canadian Wildfires"
        hCostUSOn  = scatter(axC, nan, nan, 12, 'filled', ...
            'MarkerFaceColor',[0 0.4470 0.7410], ...
            'MarkerEdgeColor',[0 0.4470 0.7410]);
        hCostUSOff = scatter(axC, nan, nan, 12, 'filled', ...
            'MarkerFaceColor','k', ...
            'MarkerEdgeColor','k');
        hCostPareto = scatter(axC, nan, nan, 12, 'filled', ...
            'MarkerFaceColor',[0.85 0.33 0.10], ...
            'MarkerEdgeColor','k', ...
            'LineWidth',0.75);
        hCostParetoLine = plot(axC, nan, nan, '-', ...
            'Color',[0.85 0.33 0.10], ...
            'LineWidth',1.5);
        hCostBase   = scatter(axC, nan, nan, 40, 'filled', 'r');

        legend(axC, [hCostPareto, hCostUSOff, hCostUSOn, hCostBase], ...
            {'Pareto','US Off','US On','Baseline'}, ...
            'Location','northwest');
    else
        hCostUSOn   = scatter(axC, nan, nan, 12, 'filled');
        % This placeholder is unused for non-US/Canada cases, but is kept so updatePlots can use the same inputs.
        hCostUSOff  = scatter(axC, nan, nan, 12, 'filled');
        hCostPareto = scatter(axC, nan, nan, 12, 'filled', ...
            'MarkerFaceColor',[0.85 0.33 0.10], ...
            'MarkerEdgeColor','k', ...
            'LineWidth',0.75);
        hCostParetoLine = plot(axC, nan, nan, '-', ...
            'Color',[0.85 0.33 0.10], ...
            'LineWidth',1.5);
        hCostBase   = scatter(axC, nan, nan, 40, 'filled', 'r');
    end

    % Create the live plot for complexity versus total CO2 estimate.
    figCO2 = figure('Color','w','Name','Complexity vs Total CO2');
    axCO2 = axes('Parent',figCO2);
    hold(axCO2,'on'); grid(axCO2,'on');
    xlabel(axCO2,'Total CO_2 [MMT]'); ylabel(axCO2,'Total Complexity');
    title(axCO2,['Total CO_2 vs Total Complexity - ' char(scenarioCfg.name)]);

    % For the Canada/US case, create separate markers for US aid on and US aid off cases.
    if SCENARIO == "US/Canadian Wildfires"
        hCO2USOn  = scatter(axCO2, nan, nan, 12, 'filled', ...
            'MarkerFaceColor',[0 0.4470 0.7410], ...
            'MarkerEdgeColor',[0 0.4470 0.7410]);
        hCO2USOff = scatter(axCO2, nan, nan, 12, 'filled', ...
            'MarkerFaceColor','k', ...
            'MarkerEdgeColor','k');
        hCO2Pareto = scatter(axCO2, nan, nan, 12, 'filled', ...
            'MarkerFaceColor',[0.85 0.33 0.10], ...
            'MarkerEdgeColor','k', ...
            'LineWidth',0.75);
        hCO2ParetoLine = plot(axCO2, nan, nan, '-', ...
            'Color',[0.85 0.33 0.10], ...
            'LineWidth',1.5);
        hCO2Base   = scatter(axCO2, nan, nan, 40, 'filled', 'r');

        legend(axCO2, [hCO2Pareto, hCO2USOff, hCO2USOn, hCO2Base], ...
            {'Pareto','US Off','US On','Baseline'}, ...
            'Location','northwest');
    else
        hCO2USOn   = scatter(axCO2, nan, nan, 12, 'filled');
        % This placeholder is unused for non-US/Canada cases, but is kept so updatePlots can use the same inputs.
        hCO2USOff  = scatter(axCO2, nan, nan, 12, 'filled');
        hCO2Pareto = scatter(axCO2, nan, nan, 12, 'filled', ...
            'MarkerFaceColor',[0.85 0.33 0.10], ...
            'MarkerEdgeColor','k', ...
            'LineWidth',0.75);
        hCO2ParetoLine = plot(axCO2, nan, nan, '-', ...
            'Color',[0.85 0.33 0.10], ...
            'LineWidth',1.5);
        hCO2Base   = scatter(axCO2, nan, nan, 40, 'filled', 'r');
    end

    % Add a reference line for global daily aviation emissions on the CO2 plot.
    AVIATION_DAILY_AVG_MMT = 2.6;
    hAviation = xline(axCO2, AVIATION_DAILY_AVG_MMT, '--', ...
        'Global Daily Aviation Emissions (2.6 MMT)', ...
        'LabelVerticalAlignment','bottom', ...
        'LabelHorizontalAlignment','left');

    % Create a comparison plot showing no-delay, min-delay, and max-delay resolution times.
    figDelayRes = figure('Color','w','Name','Complexity vs Resolution Time (Delay Comparison)');
    axDelayRes = axes('Parent',figDelayRes);
    hold(axDelayRes,'on'); grid(axDelayRes,'on');
    xlabel(axDelayRes,'Resolution Time [Days]');
    ylabel(axDelayRes,'Total Complexity');
    title(axDelayRes,['Resolution Time vs Complexity - ' char(scenarioCfg.name)]);
    hResNo   = scatter(axDelayRes, nan, nan, 12, 'filled');
    hResMin  = scatter(axDelayRes, nan, nan, 12, 'filled');
    hResMax  = scatter(axDelayRes, nan, nan, 12, 'filled');
    legend(axDelayRes, {'No delay','Min delay','Max delay'}, 'Location','northwest');

    % Create a comparison plot showing no-delay, min-delay, and max-delay CO2 values.
    figDelayCO2 = figure('Color','w','Name','Complexity vs CO2 (Delay Comparison)');
    axDelayCO2 = axes('Parent',figDelayCO2);
    hold(axDelayCO2,'on'); grid(axDelayCO2,'on');
    xlabel(axDelayCO2,'Total CO_2 [MMT]');
    ylabel(axDelayCO2,'Total Complexity');
    title(axDelayCO2,['CO_2 vs Complexity - ' char(scenarioCfg.name)]);
    hCO2No   = scatter(axDelayCO2, nan, nan, 12, 'filled');
    hCO2Min  = scatter(axDelayCO2, nan, nan, 12, 'filled');
    hCO2Max  = scatter(axDelayCO2, nan, nan, 12, 'filled');
    legend(axDelayCO2, {'No delay','Min delay','Max delay'}, 'Location','northwest');

    % Create a paired plot comparing min-delay and max-delay CO2 for each configuration.
    figCO2Pair = figure('Color','w','Name','Min Delay CO2 vs Max Delay CO2');
    axCO2Pair = axes('Parent',figCO2Pair);
    hold(axCO2Pair,'on'); grid(axCO2Pair,'on');
    xlabel(axCO2Pair,'CO_2 [MMT] - Min Delay');
    ylabel(axCO2Pair,'CO_2 [MMT] - Max Delay');
    title(axCO2Pair,['Min-Delay CO_2 vs Max-Delay CO_2 - ' char(scenarioCfg.name)]);
    hCO2Pair = scatter(axCO2Pair, nan, nan, 12, 'filled');
    hCO2PairBase = scatter(axCO2Pair, nan, nan, 40, 'filled', 'r');
    legend(axCO2Pair, {'Configurations','Baseline'}, 'Location','northwest');

    % Create a paired plot comparing min-delay and max-delay resolution time for each configuration.
    figResPair = figure('Color','w','Name','Min Delay Resolution vs Max Delay Resolution');
    axResPair = axes('Parent',figResPair);
    hold(axResPair,'on'); grid(axResPair,'on');
    xlabel(axResPair,'Resolved Day - Min Delay');
    ylabel(axResPair,'Resolved Day - Max Delay');
    title(axResPair,['Min-Delay Resolution Day vs Max-Delay Resolution Day - ' char(scenarioCfg.name)]);
    hResPair = scatter(axResPair, nan, nan, 12, 'filled');
    hResPairBase = scatter(axResPair, nan, nan, 40, 'filled', 'r');
    legend(axResPair, {'Configurations','Baseline'}, 'Location','northwest');

    drawnow;
else
    ax = []; hScatterUSOn = []; hScatterUSOff = []; hPareto = []; hParetoLine = []; hBase = [];
    axC = []; hCostUSOn = []; hCostUSOff = []; hCostPareto = []; hCostParetoLine = []; hCostBase = [];
    axCO2 = []; hCO2USOn = []; hCO2USOff = []; hCO2Pareto = []; hCO2ParetoLine = []; hCO2Base = []; hAviation = [];
end

% Make export_now available from the MATLAB Command Window while the sweep is running.
assignin('base', 'export_now', @() export_now(outMatCheckpoint, outXlsxDefault));

% Check whether a compatible checkpoint exists and resume from it if possible.
%% Resume logic
% startIdx is the first row that will be evaluated in this run.
startIdx = 1;
% lastCompleted tracks the most recent completed iteration saved in the checkpoint.
lastCompleted = 0;

% If a checkpoint file exists, inspect it before deciding whether to resume.
if isfile(outMatCheckpoint)
    S = load(outMatCheckpoint, 'R','errFlag','errMsg','lastCompleted','SWEEP_SIGNATURE_SAVED', ...
                              'BASE_ELEM_NAMES','BASE_ELEM_IDX','M_export','gamma_MMT_per_acreDay','USGov_plot');

    % Only resume if the saved sweep signature matches the current scenario, grid, fixed values, and ordering.
    if isfield(S,'SWEEP_SIGNATURE_SAVED') && string(S.SWEEP_SIGNATURE_SAVED) == SWEEP_SIGNATURE
        if isfield(S,'R')
            R = S.R;
            if size(R,2) < 33
                R(:,end+1:33) = NaN;
            end
        end
        if isfield(S,'errFlag'), errFlag = S.errFlag; end
        if isfield(S,'errMsg'), errMsg = S.errMsg; end
        if isfield(S,'lastCompleted'), lastCompleted = S.lastCompleted; end
        if isfield(S,'BASE_ELEM_NAMES'), BASE_ELEM_NAMES = S.BASE_ELEM_NAMES; end
        if isfield(S,'BASE_ELEM_IDX'),   BASE_ELEM_IDX   = S.BASE_ELEM_IDX; end
        if isfield(S,'M_export'),        M_export        = S.M_export; end
        if isfield(S,'gamma_MMT_per_acreDay'), gamma_MMT_per_acreDay = S.gamma_MMT_per_acreDay; end
        if isfield(S,'USGov_plot'), USGov_plot = S.USGov_plot; end

        % Continue from the first iteration after the last saved one.
        startIdx = lastCompleted + 1;
        fprintf("Resuming from checkpoint at iteration i = %d\n", startIdx);

        if ENABLE_LIVE_PLOTS
            updatePlots(ax, hScatterUSOn, hScatterUSOff, hPareto, hParetoLine, hBase, ...
                axC, hCostUSOn, hCostUSOff, hCostPareto, hCostParetoLine, hCostBase, ...
                axCO2, hCO2USOn, hCO2USOff, hCO2Pareto, hCO2ParetoLine, hCO2Base, hAviation, ...
                axDelayRes, hResNo, hResMin, hResMax, ...
                axDelayCO2, hCO2No, hCO2Min, hCO2Max, ...
                axCO2Pair, hCO2Pair, hCO2PairBase, ...
                axResPair, hResPair, hResPairBase, ...
                R, errFlag, USGov_plot, scenarioCfg);
        end
    else
        warning("Checkpoint exists but signature mismatch. Starting from scratch.");
    end
end

t0 = tic;

% Run the baseline architecture first before sweeping modified configurations.
%% ---------------- Iteration 1: baseline ----------------
% Only run the baseline if the script is not resuming past iteration 1.
if startIdx <= 1
    try
        % Build the DSM configuration for the current architecture.
        cfg = build_dsm_config_no_gui(struct( ...
            'name', scenarioCfg.baselineLabel, ...
            'baseline', scenarioCfg.baselineKey));

        % Record which master elements are active in the baseline architecture.
        BASE_ELEM_IDX   = find(cfg.include_master & cfg.mult_master > 0);
        BASE_ELEM_NAMES = cfg.elements_master(BASE_ELEM_IDX);
        nBase = numel(BASE_ELEM_IDX);

        % Initialize the wide configuration export matrix using the baseline element list.
        M_export = zeros(N_total, nBase);
        M_export(1,:) = cfg.mult_master(BASE_ELEM_IDX).';

        % Compute C1, C2, C3, and total complexity for the baseline architecture.
        cres = compute_complexity_metrics(cfg, compOpts);
        R(1,11) = cres.n;
        R(1,12) = cres.C1_sum;
        R(1,13) = cres.C2_sum;
        R(1,14) = cres.C3;
        R(1,15) = cres.total;

        % Convert the DSM configuration into the resource structure expected by the performance model.
        resources = build_resources_from_cfg(cfg);

        % Build the fast-mode wildfire performance configuration for the nominal no-delay case.
        cfgPerfNom = build_perf_cfg_fast(A0_BASE_ACRES, scenarioCfg);
        % Run the wildfire performance model for this architecture.
        perf = run_perf_model(cfgPerfNom, resources);
        % Save nominal growth and delay-reference data for later min/max delay runs.
        delayRef = extract_delay_ref_from_perf(perf, cfgPerfNom);

        R(1,16) = perf.resolvedDayAbs;
        R(1,17) = perf.resolvedDaysAfterPerimeter;

        % Estimate total cost for the baseline architecture.
        costOut = compute_total_cost_from_cfg(cfg, perf, scenarioCfg.name);
        R(1,18) = costOut.totalCostUSD;
        R(1,19) = costOut.totalAssetCostUSD;
        R(1,20) = costOut.totalUseCostUSD;

        % Store burn burden, measured as the area-under-curve of burned area over time.
        R(1,21) = getFieldAny(perf, {'AUC_total_acreDays'}, NaN);

        % Pull the baseline CO2 estimate from the performance output if available.
        CO2_base = getFieldAny(perf, {'CO2_baseline_MMT','CO2_est_millionMetricTons'}, NaN);
        AUC_base = R(1,21);

        % Use the baseline run to calibrate the CO2-per-acre-day scaling factor.
        if ~isnan(CO2_base) && CO2_base > 0 && ~isnan(AUC_base) && AUC_base > 0
            gamma_MMT_per_acreDay = CO2_base / AUC_base;
        else
            gamma_MMT_per_acreDay = NaN;
        end

        if ~isnan(gamma_MMT_per_acreDay) && ~isnan(R(1,21))
            R(1,22) = gamma_MMT_per_acreDay * R(1,21);
        else
            R(1,22) = NaN;
        end

        % If observation analysis is enabled, compute satellite observation gaps and delay-case performance.
        if USE_STK_OBS
            % Compute EO, weather, and combined satellite observation gap metrics from the cache.
            obs = compute_obs_metrics_from_cfg(cfg, stkObs);
            R(1,23) = obs.EO_MinObsGap_hr;
            R(1,24) = obs.EO_MaxObsGap_hr;
            R(1,25) = obs.Weather_MinObsGap_hr;
            R(1,26) = obs.AllSat_MinObsGap_hr;
            R(1,27) = obs.AllSat_MaxObsGap_hr;

            % Convert the minimum all-satellite observation gap from hours to days.
            minDelayDays = R(1,26) / 24;
            if ~isnan(minDelayDays) && minDelayDays > 0
                cfgPerfMin = build_perf_cfg_fast_with_delay(delayRef, minDelayDays, scenarioCfg);
                perfMin = run_perf_model(cfgPerfMin, resources);

                R(1,28) = getFieldAny(perfMin, {'resolvedDayAbs'}, NaN);
                R(1,30) = getFieldAny(perfMin, {'AUC_total_acreDays'}, NaN);
                if ~isnan(gamma_MMT_per_acreDay) && ~isnan(R(1,30))
                    R(1,32) = gamma_MMT_per_acreDay * R(1,30);
                end
            else
                R(1,28) = R(1,16);
                R(1,30) = R(1,21);
                R(1,32) = R(1,22);
            end

            % Convert the maximum all-satellite observation gap from hours to days.
            maxDelayDays = R(1,27) / 24;
            if ~isnan(maxDelayDays) && maxDelayDays > 0
                cfgPerfMax = build_perf_cfg_fast_with_delay(delayRef, maxDelayDays, scenarioCfg);
                perfMax = run_perf_model(cfgPerfMax, resources);

                R(1,29) = getFieldAny(perfMax, {'resolvedDayAbs'}, NaN);
                R(1,31) = getFieldAny(perfMax, {'AUC_total_acreDays'}, NaN);
                if ~isnan(gamma_MMT_per_acreDay) && ~isnan(R(1,31))
                    R(1,33) = gamma_MMT_per_acreDay * R(1,31);
                end
            else
                R(1,29) = R(1,16);
                R(1,31) = R(1,21);
                R(1,33) = R(1,22);
            end
        end

        fprintf("Baseline done | scenario=%s | n=%d | C=%.4f | resolvedDay=%.3f | cost=$%.3g | AUC=%.3g | gamma=%.3g | CO2=%.3g\n", ...
            scenarioCfg.name, cres.n, cres.total, R(1,16), R(1,18), R(1,21), gamma_MMT_per_acreDay, R(1,22));

    % If the baseline fails, save the error and allow the script to continue cleanly.
    catch ME
        errFlag(1) = true;
        errMsg(1)  = string(ME.message);
        fprintf("Baseline failed: %s\n", ME.message);

        BASE_ELEM_IDX = [];
        BASE_ELEM_NAMES = string.empty;
        M_export = [];
        gamma_MMT_per_acreDay = NaN;
    end

    lastCompleted = 1;
    % Store the sweep signature so a future run can confirm the checkpoint matches the current setup.
    SWEEP_SIGNATURE_SAVED = SWEEP_SIGNATURE;
    save(outMatCheckpoint, 'R','errFlag','errMsg','lastCompleted','SWEEP_SIGNATURE_SAVED', ...
                           'BASE_ELEM_NAMES','BASE_ELEM_IDX','M_export','gamma_MMT_per_acreDay','USGov_plot','-v7.3');
end

% Evaluate each non-baseline architecture in the sweep grid.
%% ---------------- Iterations 2..N_total ----------------
% Start at iteration 2 unless resuming from a later checkpoint.
for i = max(2,startIdx):N_total
    % Convert from results-row indexing to sweep-grid indexing.
    sweepIdx = i - 1;

    % Preserve original results-matrix layout
    % Store the ten main sweep variables in the results matrix.
    R(i,1:10) = X(sweepIdx,1:10);

    % If this is a Canada/US sweep, store the USGov flag for plotting.
    if size(X,2) >= 11
        USGov_plot(i) = X(sweepIdx,11);
    else
        USGov_plot(i) = 1;
    end

    if scenarioCfg.name == "US/Canadian Wildfires" && size(X,2) >= 11
        usGovVal = X(sweepIdx,11);
        if usGovVal == 0
            fprintf('[US-AID OFF] i=%d (sweepIdx=%d)\n', i, sweepIdx);
        else 
            fprintf('[US-AID ON] i=%d (sweepIdx=%d)\n', i, sweepIdx);
        end
    end

    try
        % Convert the current sweep row into DSM multiplicity overrides.
        ov = makeOverridesFromRow(X(sweepIdx,:), fixed, scenarioCfg);

        % Build the DSM configuration for the current architecture.
        cfg = build_dsm_config_no_gui(struct( ...
            'name', sprintf("cfg_%06d", i), ...
            'baseline', scenarioCfg.baselineKey, ...
            'multOverrides', ov));

        % If the baseline element list exists, store the current multiplicities in the export matrix.
        if ~isempty(BASE_ELEM_IDX)
            M_export(i,:) = cfg.mult_master(BASE_ELEM_IDX).';
        end

        % Compute C1, C2, C3, and total complexity for the baseline architecture.
        cres = compute_complexity_metrics(cfg, compOpts);
        R(i,11) = cres.n;
        R(i,12) = cres.C1_sum;
        R(i,13) = cres.C2_sum;
        R(i,14) = cres.C3;
        R(i,15) = cres.total;

        % Convert the DSM configuration into the resource structure expected by the performance model.
        resources = build_resources_from_cfg(cfg);

        % Build the fast-mode wildfire performance configuration for the nominal no-delay case.
        cfgPerfNom = build_perf_cfg_fast(A0_BASE_ACRES, scenarioCfg);
        % Run the wildfire performance model for this architecture.
        perf = run_perf_model(cfgPerfNom, resources);
        % Save nominal growth and delay-reference data for later min/max delay runs.
        delayRef = extract_delay_ref_from_perf(perf, cfgPerfNom);

        R(i,16) = perf.resolvedDayAbs;
        R(i,17) = perf.resolvedDaysAfterPerimeter;

        % Estimate total cost for the baseline architecture.
        costOut = compute_total_cost_from_cfg(cfg, perf, scenarioCfg.name);
        R(i,18) = costOut.totalCostUSD;
        R(i,19) = costOut.totalAssetCostUSD;
        R(i,20) = costOut.totalUseCostUSD;

        % Store burn burden for the current architecture.
        R(i,21) = getFieldAny(perf, {'AUC_total_acreDays'}, NaN);

        % Convert burn burden into estimated CO2 using the baseline-calibrated scaling factor.
        if ~isnan(gamma_MMT_per_acreDay) && gamma_MMT_per_acreDay > 0 && ~isnan(R(i,21)) && R(i,21) > 0
            R(i,22) = gamma_MMT_per_acreDay * R(i,21);
        else
            R(i,22) = NaN;
        end

        % If observation analysis is enabled, compute satellite observation gaps and delay-case performance.
        if USE_STK_OBS
            % Compute EO, weather, and combined satellite observation gap metrics from the cache.
            obs = compute_obs_metrics_from_cfg(cfg, stkObs);
            R(i,23) = obs.EO_MinObsGap_hr;
            R(i,24) = obs.EO_MaxObsGap_hr;
            R(i,25) = obs.Weather_MinObsGap_hr;
            R(i,26) = obs.AllSat_MinObsGap_hr;
            R(i,27) = obs.AllSat_MaxObsGap_hr;

            % Convert minimum all-satellite observation gap from hours to days for the delay run.
            minDelayDays = R(i,26) / 24;
            if ~isnan(minDelayDays) && minDelayDays > 0
                cfgPerfMin = build_perf_cfg_fast_with_delay(delayRef, minDelayDays, scenarioCfg);
                perfMin = run_perf_model(cfgPerfMin, resources);

                R(i,28) = getFieldAny(perfMin, {'resolvedDayAbs'}, NaN);
                R(i,30) = getFieldAny(perfMin, {'AUC_total_acreDays'}, NaN);

                if ~isnan(gamma_MMT_per_acreDay) && gamma_MMT_per_acreDay > 0 && ~isnan(R(i,30))
                    R(i,32) = gamma_MMT_per_acreDay * R(i,30);
                end
            else
                R(i,28) = R(i,16);
                R(i,30) = R(i,21);
                R(i,32) = R(i,22);
            end

            % Convert maximum all-satellite observation gap from hours to days for the delay run.
            maxDelayDays = R(i,27) / 24;
            if ~isnan(maxDelayDays) && maxDelayDays > 0
                cfgPerfMax = build_perf_cfg_fast_with_delay(delayRef, maxDelayDays, scenarioCfg);
                perfMax = run_perf_model(cfgPerfMax, resources);

                R(i,29) = getFieldAny(perfMax, {'resolvedDayAbs'}, NaN);
                R(i,31) = getFieldAny(perfMax, {'AUC_total_acreDays'}, NaN);

                if ~isnan(gamma_MMT_per_acreDay) && gamma_MMT_per_acreDay > 0 && ~isnan(R(i,31))
                    R(i,33) = gamma_MMT_per_acreDay * R(i,31);
                end
            else
                R(i,29) = R(i,16);
                R(i,31) = R(i,21);
                R(i,33) = R(i,22);
            end
        end

    % If the baseline fails, save the error and allow the script to continue cleanly.
    catch ME
        errFlag(i) = true;
        errMsg(i)  = string(ME.message);
        if nnz(errFlag) <= 5 || mod(i,200)==0
            fprintf("ERROR at i=%d: %s\n", i, errMsg(i));
        end
    end

    % Mark this iteration as completed before progress reporting and checkpointing.
    lastCompleted = i;

    % Print progress early and then every 10 iterations.
    if mod(i,10)==0 || i==2
        pct = 100 * i / N_total;
        elapsed = toc(t0);
        fprintf("i=%d/%d (%.3f%%) | elapsed %.1fs | validC=%d | validP=%d | validCost=%d | validAUC=%d | validCO2=%d | validObs=%d | errors=%d\n", ...
            i, N_total, pct, elapsed, ...
            nnz(~isnan(R(:,15))), nnz(~isnan(R(:,16))), nnz(~isnan(R(:,18))), ...
            nnz(~isnan(R(:,21))), nnz(~isnan(R(:,22))), nnz(~isnan(R(:,27))), nnz(errFlag));
    end

    % Update the live plots periodically and at the final iteration.
    if ENABLE_LIVE_PLOTS && (mod(i,plotEvery)==0 || i==2 || i==N_total)
        updatePlots(ax, hScatterUSOn, hScatterUSOff, hPareto, hParetoLine, hBase, ...
            axC, hCostUSOn, hCostUSOff, hCostPareto, hCostParetoLine, hCostBase, ...
            axCO2, hCO2USOn, hCO2USOff, hCO2Pareto, hCO2ParetoLine, hCO2Base, hAviation, ...
            axDelayRes, hResNo, hResMin, hResMax, ...
            axDelayCO2, hCO2No, hCO2Min, hCO2Max, ...
            axCO2Pair, hCO2Pair, hCO2PairBase, ...
            axResPair, hResPair, hResPairBase, ...
            R, errFlag, USGov_plot, scenarioCfg);
    end

    % Save a checkpoint periodically during the sweep.
    if mod(i,checkpointEvery)==0
        SWEEP_SIGNATURE_SAVED = SWEEP_SIGNATURE;
        save(outMatCheckpoint, 'R','errFlag','errMsg','lastCompleted','SWEEP_SIGNATURE_SAVED', ...
                               'BASE_ELEM_NAMES','BASE_ELEM_IDX','M_export','gamma_MMT_per_acreDay','USGov_plot','-v7.3');
        fprintf("Checkpoint saved at i=%d\n", i);
    end
end

% Save the final MAT file and write the CSV summary after all configurations have run.
%% Final save + CSV
save(outMatFinal, 'R','errFlag','errMsg','BASE_ELEM_NAMES','BASE_ELEM_IDX','M_export','gamma_MMT_per_acreDay','USGov_plot','-v7.3');

% Convert the numeric results matrix into a table with descriptive column names.
T = array2table(R, 'VariableNames', { ...
    'VLAT','LAT','SEAT','HeliI','HeliII','HeliIII','EO','Weather','Iridium','FireEngines', ...
    'nNodes','C1','C2','C3','TotalComplexity', ...
    'ResolvedDayAbs','ResolvedDaysAfterPerimeter', ...
    'TotalCostUSD','TotalAssetCostUSD','TotalUseCostUSD', ...
    'AUC_total_acreDays','CO2Total_MMT', ...
    'EO_MinObsGap_hr','EO_MaxObsGap_hr','Weather_MinObsGap_hr', ...
    'AllSat_MinObsGap_hr','AllSat_MaxObsGap_hr', ...
    'ResolvedDayAbs_MinDelay','ResolvedDayAbs_MaxDelay', ...
    'AUC_total_MinDelay','AUC_total_MaxDelay', ...
    'CO2Total_MinDelay','CO2Total_MaxDelay'});

% Add error flags and error messages to the CSV output table.
T.ErrFlag = errFlag;
T.ErrMsg  = errMsg;
writetable(T, outCsv);

fprintf("Done. Valid complexity: %d | Valid performance: %d | Valid cost: %d | Valid AUC: %d | Valid CO2: %d | Valid Obs: %d | Errors: %d\n", ...
    nnz(~isnan(R(:,15))), nnz(~isnan(R(:,16))), nnz(~isnan(R(:,18))), ...
    nnz(~isnan(R(:,21))), nnz(~isnan(R(:,22))), nnz(~isnan(R(:,27))), nnz(errFlag));

% Optionally create the detailed Excel export at the end of the run.
if AUTO_EXPORT_XLSX_AT_END
    export_now(outMatFinal, outXlsxDefault);
end

fprintf("\nTip: export anytime with:\n  export_now\n\n");

% Local helper functions used by the main script are defined below.
%% ========================= helpers =========================

%GETSCENARIOSWEEPSETTINGS
% Returns all scenario-specific constants used by the sweep and performance model.
function scenarioCfg = getScenarioSweepSettings(SCENARIO)
    % Initialize the scenario configuration and store the selected scenario name.
    scenarioCfg = struct();
    scenarioCfg.name = string(SCENARIO);

    switch scenarioCfg.name
        case "Butte County"
            scenarioCfg.baselineKey   = 'butte';
            scenarioCfg.baselineLabel = 'Baseline (Butte)';
            scenarioCfg.A0_BASE_ACRES = 164048;

            scenarioCfg.dayPerimeter         = 1.5;
            scenarioCfg.syntheticGrowthShape = 5.0;
            scenarioCfg.naturalHalfLifeDays  = 12;

            scenarioCfg.ignLat = 39.8134;
            scenarioCfg.ignLon = -121.4347;
            scenarioCfg.centerLat = NaN;
            scenarioCfg.centerLon = NaN;

            scenarioCfg.stkObsCacheFile = 'stk_obs_cache_Butte_County.mat';
            scenarioCfg.stkStartStr     = '9 Oct 2023 14:10:00.000';
            scenarioCfg.stkStopStr      = '10 Oct 2023 14:10:00.000';
            scenarioCfg.stkFireLat      = 38.0;
            scenarioCfg.stkFireLon      = -122.5;
            scenarioCfg.stkFireAlt_km   = 0;

        case "Etosha National Park"
            scenarioCfg.baselineKey   = 'etosha';
            scenarioCfg.baselineLabel = 'Baseline (Etosha)';
            scenarioCfg.A0_BASE_ACRES = 2349296.7;

            scenarioCfg.dayPerimeter         = 8;
            scenarioCfg.syntheticGrowthShape = 3.5;
            scenarioCfg.naturalHalfLifeDays  = 2;

            scenarioCfg.ignLat = -19.222303;
            scenarioCfg.ignLon = 14.165436;
            scenarioCfg.centerLat = -18.95;
            scenarioCfg.centerLon = 16.15;

            scenarioCfg.stkObsCacheFile = 'stk_obs_cache_Etosha_National_Park.mat';
            scenarioCfg.stkStartStr     = '22 Sep 2025 00:00:00.000';
            scenarioCfg.stkStopStr      = '30 Sep 2025 23:59:59.000';
            scenarioCfg.stkFireLat      = -19.222303;
            scenarioCfg.stkFireLon      = 14.165436;
            scenarioCfg.stkFireAlt_km   = 0;

        case "US/Canadian Wildfires"
            scenarioCfg.baselineKey   = 'canada';
            scenarioCfg.baselineLabel = 'Baseline (US/Canadian)';
            scenarioCfg.A0_BASE_ACRES = 69797.8;

            scenarioCfg.dayPerimeter         = 19;
            scenarioCfg.syntheticGrowthShape = 5;
            scenarioCfg.naturalHalfLifeDays  = 18;

            scenarioCfg.ignLat = 43.669124;
            scenarioCfg.ignLon = -65.355936;
            scenarioCfg.centerLat = 43.669124;
            scenarioCfg.centerLon = -65.355936;

            scenarioCfg.stkObsCacheFile = 'stk_obs_cache_US_Canadian_Wildfires.mat';
            scenarioCfg.stkStartStr     = '27 May 2023 00:00:00.000';
            scenarioCfg.stkStopStr      = '21 Jun 2023 23:59:59.000';
            scenarioCfg.stkFireLat      = 43.669124;
            scenarioCfg.stkFireLon      = -65.355936;
            scenarioCfg.stkFireAlt_km   = 0;

        otherwise
            error('Unknown SCENARIO: %s', scenarioCfg.name);
    end
end

%RUN_PERF_MODEL
% Thin wrapper around wildfire_performance_model to keep the main loop readable.
function perf = run_perf_model(cfgPerf, resources)
    % Pass the performance configuration and architecture resources into the wildfire model.
    perf = wildfire_performance_model(cfgPerf, resources);
end

%BUILD_PERF_CFG_FAST
% Builds a fast-mode performance-model configuration for nominal no-delay runs.
function cfgPerf = build_perf_cfg_fast(A0_acres, scenarioCfg)
    % Start with an empty performance configuration and enable fast mode.
    cfgPerf = struct();
    cfgPerf.fastMode = true;
    cfgPerf.selectedScenario = scenarioCfg.name;

    cfgPerf.A0_override_acres = A0_acres;
    cfgPerf.A0_nominal_override_acres = A0_acres;

    cfgPerf.dayPerimeter        = scenarioCfg.dayPerimeter;
    cfgPerf.plotSuppression     = true;
    cfgPerf.supp_dtHours        = 0.25;
    cfgPerf.supp_tMaxDays       = 40;
    cfgPerf.naturalHalfLifeDays = scenarioCfg.naturalHalfLifeDays;
    cfgPerf.doFigures           = false;
    cfgPerf.detectionDelayDays  = 0;

    cfgPerf.synthesizeNominalGrowth = true;
    cfgPerf.syntheticGrowthShape    = scenarioCfg.syntheticGrowthShape;

    cfgPerf.ignLat = scenarioCfg.ignLat;
    cfgPerf.ignLon = scenarioCfg.ignLon;

    if isfinite(scenarioCfg.centerLat)
        cfgPerf.centerLat = scenarioCfg.centerLat;
    end
    if isfinite(scenarioCfg.centerLon)
        cfgPerf.centerLon = scenarioCfg.centerLon;
    end
end

%BUILD_PERF_CFG_FAST_WITH_DELAY
% Builds a performance-model configuration that includes a detection delay.
function cfgPerf = build_perf_cfg_fast_with_delay(delayRef, delayDays, scenarioCfg)
    if nargin < 1 || isempty(delayRef)
        error('build_perf_cfg_fast_with_delay requires delayRef.');
    end

    if isfield(delayRef,'A0_nominal_override_acres') && isfinite(delayRef.A0_nominal_override_acres)
        A0_use = delayRef.A0_nominal_override_acres;
    elseif isfield(delayRef,'A0_override_acres') && isfinite(delayRef.A0_override_acres)
        A0_use = delayRef.A0_override_acres;
    else
        error('delayRef is missing a valid A0 nominal value.');
    end

    cfgPerf = build_perf_cfg_fast(A0_use, scenarioCfg);
    cfgPerf.detectionDelayDays = delayDays;

    if isfield(delayRef,'A0_nominal_override_acres') && isfinite(delayRef.A0_nominal_override_acres)
        cfgPerf.A0_nominal_override_acres = delayRef.A0_nominal_override_acres;
    end

    if isfield(delayRef,'nominalGrowth_tDays') && ~isempty(delayRef.nominalGrowth_tDays)
        cfgPerf.nominalGrowth_tDays = delayRef.nominalGrowth_tDays;
    end

    if isfield(delayRef,'nominalGrowth_areaAcres') && ~isempty(delayRef.nominalGrowth_areaAcres)
        cfgPerf.nominalGrowth_areaAcres = delayRef.nominalGrowth_areaAcres;
    end

    if isfield(delayRef,'delaySlopeAcresPerDay') && isfinite(delayRef.delaySlopeAcresPerDay)
        cfgPerf.delaySlopeAcresPerDay = delayRef.delaySlopeAcresPerDay;
    end
end

%EXTRACT_DELAY_REF_FROM_PERF
% Pulls nominal growth and baseline-fire information needed to run delay cases consistently.
function delayRef = extract_delay_ref_from_perf(perf, cfgPerfNom)
    delayRef = struct();

    delayRef.A0_nominal_override_acres = getFieldAny(perf, {'A0_perimeterDay_acres','A0_delayed_acres'}, NaN);
    if ~isfinite(delayRef.A0_nominal_override_acres) || delayRef.A0_nominal_override_acres <= 0
        delayRef.A0_nominal_override_acres = getFieldAny(cfgPerfNom, {'A0_override_acres'}, NaN);
    end

    delayRef.nominalGrowth_tDays = getFieldAny(perf, {'nominalGrowth_tDays'}, []);
    delayRef.nominalGrowth_areaAcres = getFieldAny(perf, {'nominalGrowth_areaAcres'}, []);
    delayRef.delaySlopeAcresPerDay = getFieldAny(perf, {'delaySlopeAcresPerDay'}, NaN);
    delayRef.selectedScenario = getFieldAny(cfgPerfNom, {'selectedScenario'}, "Butte County");

    delayRef.dayPerimeter = getFieldAny(cfgPerfNom, {'dayPerimeter'}, NaN);
    delayRef.syntheticGrowthShape = getFieldAny(cfgPerfNom, {'syntheticGrowthShape'}, 5.0);
end

%BUILD_RESOURCES_FROM_CFG
% Extracts the resource arrays needed by the wildfire performance model.
function resources = build_resources_from_cfg(cfg)
    resources = struct();
    resources.expandedElements  = cfg.expandedElements;
    resources.expandedSuppVal   = cfg.expandedSuppVal;
    resources.expandedCycleDays = cfg.expandedCycleDays;
end

%MAKEOVERRIDESFROMROW
% Converts one sweep-grid row into a containers.Map of architecture multiplicity overrides.
function ov = makeOverridesFromRow(x, fixed, scenarioCfg)
    % Overrides are stored as a map where keys are element names and values are multiplicities.
    ov = containers.Map;

    vlat    = x(1);
    lat     = x(2);
    seat    = x(3);
    heliI   = x(4);
    heliII  = x(5);
    heliIII = x(6);
    eo      = x(7);
    weather = x(8);
    iridium = x(9);
    fireEng = x(10);

    leadPlanes = fixed.LeadPlanes;
    smokejump  = fixed.Smokejump;
    uas        = fixed.UAS;
    viirs      = fixed.VIIRS;
    airbase    = fixed.Airbase;
    c3         = fixed.C3;

    switch string(scenarioCfg.name)
        case "US/Canadian Wildfires"
            usGovOn = true;
            if numel(x) >= 11
                usGovOn = logical(x(11));
            end

            ov('U.S. Federal Government') = double(usGovOn);

            if ~usGovOn
                % ---- Debug: entering US perturbation ----
                if ~usGovOn
                    fprintf('   -> Applying US-AID-OFF overrides\n');
                end
                % Remove selected U.S.-side organizational elements if no
                % US involvement
                ov('Federal Emergency Management Agency') = 0;
                ov('National Interagency Fire Center') = 0;
                ov('US Forest Service') = 0;
                ov('US Department of Defense (DOD)') = 0;
                ov('U.S. Department of State') =  0;
                ov('U.S. Federal Government') = 0;
                ov('Military Organizations (US National Guard/DOD)') = 0;
                ov('FAA') = 0;

                % Cut selected operational assets/support in half if no US
                % involvement
                vlat       = floor(0.5 * vlat);
                lat        = floor(0.5 * lat);
                seat       = floor(0.5 * seat);
                heliI      = floor(0.5 * heliI);
                heliII     = floor(0.5 * heliII);
                heliIII    = floor(0.5 * heliIII);
                fireEng    = floor(0.5 * fireEng);

                leadPlanes = floor(0.5 * leadPlanes);
                smokejump  = floor(0.5 * smokejump);
                uas        = floor(0.5 * uas);
                airbase    = floor(0.5 * airbase);
                
                % Note: This is the c3 element not the complexity metric
                if fixed.C3 > 0
                    c3 = max(1, floor(0.5 * fixed.C3));
                end
            else
                ov('Federal Emergency Management Agency') = 1;
                ov('National Interagency Fire Center') = 1;
                ov('US Forest Service') = 1;
                ov('US Department of Defense (DOD)') = 1;
                ov('U.S. Department of State') =  1;
                ov('U.S. Federal Government') = 1;
                ov('Military Organizations (US National Guard/DOD)') = 1;
                ov('FAA') = 1;
            end
    end

    ov('Very Large Air Tankers') = vlat;
    ov('Large Air Tankers') = lat;
    ov('Single Engine Airtankers') = seat;
    ov('Helicopters Type I') = heliI;
    ov('Helicopters Type II') = heliII;
    ov('Helicopters Type III') = heliIII;
    ov('EO Satellites (OroraTech)') = eo;
    ov('Weather Satellites (GOES-16/GOES-18)') = weather;
    ov('Comms Satellites (Iridium)') = iridium;
    ov('Fire Engines') = fireEng;

    ov('Tactical Lead Planes') = leadPlanes;
    ov('Smokejumper Aircraft') = smokejump;
    ov('Tactical UAS') = uas;
    ov('Satellite Imagery Systems (VIIRS Pipeline)') = viirs;
    ov('Airbase Support Systems') = airbase;
    ov('C3 Systems') = c3;
end

%UPDATEPLOTS
% Refreshes all live plots using the current contents of the results matrix.
function updatePlots(ax, hScatterUSOn, hScatterUSOff, hPareto, hParetoLine, hBase, ...
                     axC, hCostUSOn, hCostUSOff, hCostPareto, hCostParetoLine, hCostBase, ...
                     axCO2, hCO2USOn, hCO2USOff, hCO2Pareto, hCO2ParetoLine, hCO2Base, hAviation, ...
                     axDelayRes, hResNo, hResMin, hResMax, ...
                     axDelayCO2, hCO2No, hCO2Min, hCO2Max, ...
                     axCO2Pair, hCO2Pair, hCO2PairBase, ...
                     axResPair, hResPair, hResPairBase, ...
                     R, errFlag, USGov_plot, scenarioCfg)

    % -------- Complexity vs Resolution --------
    good = ~errFlag & ~isnan(R(:,15)) & ~isnan(R(:,16));
    x = R(good,16);
    y = R(good,15);

    if scenarioCfg.name == "US/Canadian Wildfires"
        u = USGov_plot(good);
        idxOn  = (u == 1);
        idxOff = (u == 0);

        set(hScatterUSOn,  'XData', x(idxOn),  'YData', y(idxOn));
        set(hScatterUSOff, 'XData', x(idxOff), 'YData', y(idxOff));
    else
        set(hScatterUSOn,  'XData', x,   'YData', y);
        set(hScatterUSOff, 'XData', nan, 'YData', nan);
    end

    pMask = pareto_front_mask_min2(x, y);
    xp = x(pMask);
    yp = y(pMask);

    [~, ord] = sort(xp);
    xp = xp(ord);
    yp = yp(ord);

    set(hPareto, 'XData', xp, 'YData', yp);
    set(hParetoLine, 'XData', xp, 'YData', yp);

    if ~isnan(R(1,16)) && ~isnan(R(1,15)) && ~errFlag(1)
        set(hBase,'XData',R(1,16),'YData',R(1,15));
    end

    title(ax, sprintf('Complexity vs Resolution Time | valid=%d | pareto=%d | errors=%d', ...
        nnz(good), nnz(pMask), nnz(errFlag)));
    if any(good)
        xlim(ax,[0, max(1, max(x)*1.05)]);
    end

    % -------- Complexity vs Cost --------
    good2 = ~errFlag & ~isnan(R(:,15)) & ~isnan(R(:,18));
    xAll = R(:,18) / 1e6;
    x = xAll(good2);
    y = R(good2,15);

    if scenarioCfg.name == "US/Canadian Wildfires"
        u = USGov_plot(good2);
        idxOn  = (u == 1);
        idxOff = (u == 0);

        set(hCostUSOn,  'XData', x(idxOn),  'YData', y(idxOn));
        set(hCostUSOff, 'XData', x(idxOff), 'YData', y(idxOff));
    else
        set(hCostUSOn,  'XData', x,   'YData', y);
        set(hCostUSOff, 'XData', nan, 'YData', nan);
    end

    pMask = pareto_front_mask_min2(x, y);
    xp = x(pMask);
    yp = y(pMask);

    [~, ord] = sort(xp);
    xp = xp(ord);
    yp = yp(ord);

    set(hCostPareto, 'XData', xp, 'YData', yp);
    set(hCostParetoLine, 'XData', xp, 'YData', yp);

    if ~isnan(xAll(1)) && ~isnan(R(1,15)) && ~errFlag(1)
        set(hCostBase,'XData', xAll(1), 'YData', R(1,15));
    end

    title(axC, sprintf('Complexity vs Total Cost | valid=%d | pareto=%d | errors=%d', ...
        nnz(good2), nnz(pMask), nnz(errFlag)));
    if any(good2)
        xlim(axC, [0, max(1e-6, max(x)*1.05)]);
    end

    % -------- Complexity vs CO2 --------
    good3 = ~errFlag & ~isnan(R(:,15)) & ~isnan(R(:,22));
    x = R(good3,22);
    y = R(good3,15);

    if scenarioCfg.name == "US/Canadian Wildfires"
        u = USGov_plot(good3);
        idxOn  = (u == 1);
        idxOff = (u == 0);

        set(hCO2USOn,  'XData', x(idxOn),  'YData', y(idxOn));
        set(hCO2USOff, 'XData', x(idxOff), 'YData', y(idxOff));
    else
        set(hCO2USOn,  'XData', x,   'YData', y);
        set(hCO2USOff, 'XData', nan, 'YData', nan);
    end

    pMask = pareto_front_mask_min2(x, y);
    xp = x(pMask);
    yp = y(pMask);

    [~, ord] = sort(xp);
    xp = xp(ord);
    yp = yp(ord);

    set(hCO2Pareto, 'XData', xp, 'YData', yp);
    set(hCO2ParetoLine, 'XData', xp, 'YData', yp);

    if ~isnan(R(1,22)) && ~isnan(R(1,15)) && ~errFlag(1)
        set(hCO2Base,'XData', R(1,22), 'YData', R(1,15));
    end

    title(axCO2, sprintf('Complexity vs Total CO2 Emissions | valid=%d | pareto=%d | errors=%d', ...
        nnz(good3), nnz(pMask), nnz(errFlag)));
    if any(good3)
        xlim(axCO2, [0, max(1e-6, max(x)*1.05)]);
    end

    if ~isempty(hAviation) && isvalid(hAviation)
        uistack(hAviation,'top');
    end

    % -------- New: Resolution vs Complexity (No / Min / Max Delay) --------
    goodNo = ~errFlag & ~isnan(R(:,15)) & ~isnan(R(:,16));
    set(hResNo, 'XData', R(goodNo,16), 'YData', R(goodNo,15));

    goodMin = ~errFlag & ~isnan(R(:,15)) & ~isnan(R(:,28));
    set(hResMin, 'XData', R(goodMin,28), 'YData', R(goodMin,15));

    goodMax = ~errFlag & ~isnan(R(:,15)) & ~isnan(R(:,29));
    set(hResMax, 'XData', R(goodMax,29), 'YData', R(goodMax,15));

    if any(goodNo | goodMin | goodMax)
        xAll = [R(goodNo,16); R(goodMin,28); R(goodMax,29)];
        xlim(axDelayRes, [0, max(1, max(xAll)*1.05)]);
    end

    % -------- New: CO2 vs Complexity (No / Min / Max Delay) --------
    goodNo = ~errFlag & ~isnan(R(:,15)) & ~isnan(R(:,22));
    set(hCO2No, 'XData', R(goodNo,22), 'YData', R(goodNo,15));

    goodMin = ~errFlag & ~isnan(R(:,15)) & ~isnan(R(:,32));
    set(hCO2Min, 'XData', R(goodMin,32), 'YData', R(goodMin,15));

    goodMax = ~errFlag & ~isnan(R(:,15)) & ~isnan(R(:,33));
    set(hCO2Max, 'XData', R(goodMax,33), 'YData', R(goodMax,15));

    if any(goodNo | goodMin | goodMax)
        xAll = [R(goodNo,22); R(goodMin,32); R(goodMax,33)];
        xlim(axDelayCO2, [0, max(1e-6, max(xAll)*1.05)]);
    end

    % -------- New: Min-delay CO2 vs Max-delay CO2 --------
    goodPairCO2 = ~errFlag & ~isnan(R(:,32)) & ~isnan(R(:,33));
    xPairCO2 = R(goodPairCO2,32);
    yPairCO2 = R(goodPairCO2,33);

    set(hCO2Pair, 'XData', xPairCO2, 'YData', yPairCO2);

    if ~errFlag(1) && ~isnan(R(1,32)) && ~isnan(R(1,33))
        set(hCO2PairBase, 'XData', R(1,32), 'YData', R(1,33));
    end

    if any(goodPairCO2)
        limMax = max([xPairCO2; yPairCO2]);
        limMax = max(limMax, 1e-6);
        lims = [0, 1.05*limMax];
        xlim(axCO2Pair, lims);
        ylim(axCO2Pair, lims);
    end

    % -------- New: Min-delay Resolution vs Max-delay Resolution --------
    goodPairRes = ~errFlag & ~isnan(R(:,28)) & ~isnan(R(:,29));
    xPairRes = R(goodPairRes,28);
    yPairRes = R(goodPairRes,29);

    set(hResPair, 'XData', xPairRes, 'YData', yPairRes);

    if ~errFlag(1) && ~isnan(R(1,28)) && ~isnan(R(1,29))
        set(hResPairBase, 'XData', R(1,28), 'YData', R(1,29));
    end

    if any(goodPairRes)
        limMax = max([xPairRes; yPairRes]);
        limMax = max(limMax, 1);
        lims = [0, 1.05*limMax];
        xlim(axResPair, lims);
        ylim(axResPair, lims);
    end

    uistack(hParetoLine,'top');
    uistack(hCostParetoLine,'top');
    uistack(hCO2ParetoLine,'top');
    uistack(hPareto,'top');
    uistack(hCostPareto,'top');
    uistack(hCO2Pareto,'top');
    uistack(hBase,'top');
    uistack(hCostBase,'top');
    uistack(hCO2Base,'top');

    drawnow limitrate;
end

%COMPUTE_TOTAL_COST_FROM_CFG
% Estimates total cost from asset cost, repeated-use cost, and firefighter labor.
function out = compute_total_cost_from_cfg(cfg, perf, scenarioName)
    % Initialize output structure for cost components.
    out = struct();

    % Sum the expanded asset acquisition/replacement costs when available.
    if isfield(cfg,'expandedAssetCostUSD') && ~isempty(cfg.expandedAssetCostUSD)
        totalAsset = nansum(cfg.expandedAssetCostUSD);
    else
        totalAsset = NaN;
    end

    if ~isfield(perf,'dayPerimeter') || isnan(perf.dayPerimeter)
        dayPerim = 0;
    else
        dayPerim = perf.dayPerimeter;
    end

    if ~isfield(perf,'resolvedDayAbs') || isnan(perf.resolvedDayAbs)
        totalUse = NaN;
    else
        tEndPost = max(0, perf.resolvedDayAbs - dayPerim);
        totalUse = estimate_use_cost(cfg, tEndPost);
    end

    firefighterHourlyUSD   = 50;
    firefighterHoursPerDay = 12;

    switch string(scenarioName)
        case "Butte County"
            nFirefighters = 1022;
        case "Etosha National Park"
            nFirefighters = 500;
        case "US/Canadian Wildfires"
            nFirefighters = 3000;
            if ~get_us_aid_flag_from_cfg(cfg)
                nFirefighters = floor(0.5 * nFirefighters);
            end
        otherwise
            warning('Unknown scenario "%s" in compute_total_cost_from_cfg. Defaulting to 1022 firefighters.', string(scenarioName));
            nFirefighters = 1022;
    end

    if ~isfield(perf,'resolvedDayAbs') || isnan(perf.resolvedDayAbs)
        firefighterLaborUSD = NaN;
    else
        firefighterLaborUSD = nFirefighters * firefighterHourlyUSD * firefighterHoursPerDay * perf.resolvedDayAbs;
    end

    out.totalAssetCostUSD       = totalAsset;
    out.totalUseCostUSD         = totalUse;
    out.firefighterLaborCostUSD = firefighterLaborUSD;
    out.totalCostUSD            = totalAsset + totalUse + firefighterLaborUSD;
end

%GET_US_AID_FLAG_FROM_CFG
% Checks whether the U.S. Federal Government element is active in a Canada/US configuration.
function usAidOn = get_us_aid_flag_from_cfg(cfg)
    % Default to US aid on unless the configuration explicitly removes it.
    usAidOn = true;

    if isfield(cfg,'elements_master') && isfield(cfg,'mult_master')
        names = string(cfg.elements_master(:));
        mults = cfg.mult_master(:);

        idx = strcmp(names, "U.S. Federal Government");
        if any(idx)
            usAidOn = any(mults(idx) > 0);
        end
    end
end

%ESTIMATE_USE_COST
% Estimates repeated asset-use cost over the post-perimeter suppression window.
function totalUseUSD = estimate_use_cost(cfg, tEndPostDays)
    % Pull expanded element names and cycle times from the architecture configuration.
    elems = string(cfg.expandedElements(:));
    cyc   = cfg.expandedCycleDays(:);

    if isfield(cfg,'expandedCostPerUseUSD')
        cUse = cfg.expandedCostPerUseUSD(:);
    else
        cUse = nan(size(elems));
    end

    if isempty(elems) || isempty(cyc) || isempty(cUse) || tEndPostDays <= 0
        totalUseUSD = 0;
        return;
    end

    [uNames,~,g] = unique(elems, 'stable');
    totalUseUSD = 0;

    for i = 1:numel(uNames)
        idx = (g == i);
        m = sum(idx);

        Td = median(cyc(idx), 'omitnan');
        costPerUse = median(cUse(idx), 'omitnan');

        if isnan(Td) || Td <= 0 || isnan(costPerUse) || costPerUse <= 0
            continue;
        end

        deltaDays = Td / max(1,m);
        t0 = 0.5 * Td;

        if t0 > tEndPostDays
            nUses = 0;
        else
            nUses = numel(t0 : deltaDays : tEndPostDays);
        end

        totalUseUSD = totalUseUSD + costPerUse * nUses;
    end
end

%BUILD_TABLES
% Builds summary and wide-format tables for Excel export.
function [Tsum, Twide] = build_tables(R, errFlag, errMsg, BASE_ELEM_NAMES, M_export)
    Tsum = array2table(R, 'VariableNames', { ...
        'VLAT','LAT','SEAT','HeliI','HeliII','HeliIII','EO','Weather','Iridium','FireEngines', ...
        'nNodes','C1','C2','C3','TotalComplexity', ...
        'ResolvedDayAbs','ResolvedDaysAfterPerimeter', ...
        'TotalCostUSD','TotalAssetCostUSD','TotalUseCostUSD', ...
        'AUC_total_acreDays','CO2Total_MMT', ...
        'EO_MinObsGap_hr','EO_MaxObsGap_hr','Weather_MinObsGap_hr', ...
        'AllSat_MinObsGap_hr','AllSat_MaxObsGap_hr', ...
        'ResolvedDayAbs_MinDelay','ResolvedDayAbs_MaxDelay', ...
        'AUC_total_MinDelay','AUC_total_MaxDelay', ...
        'CO2Total_MinDelay','CO2Total_MaxDelay'});
    Tsum.ErrFlag = errFlag;
    Tsum.ErrMsg  = errMsg;

    n = size(R,1);
    configNum = (1:n).';

    if isempty(BASE_ELEM_NAMES) || isempty(M_export)
        Twide = table(configNum, 'VariableNames', {'ConfigNum'});
        Twide.TotalComplexity         = R(:,15);
        Twide.ResolvedDayAbs          = R(:,16);
        Twide.TotalCost_MUSD          = R(:,18) / 1e6;
        Twide.AUC_total_acreDays      = R(:,21);
        Twide.CO2Total_MMT            = R(:,22);
        Twide.EO_MinObsGap_hr         = R(:,23);
        Twide.EO_MaxObsGap_hr         = R(:,24);
        Twide.Weather_MinObsGap_hr    = R(:,25);
        Twide.AllSat_MinObsGap_hr     = R(:,26);
        Twide.AllSat_MaxObsGap_hr     = R(:,27);
        Twide.ResolvedDayAbs_MinDelay = R(:,28);
        Twide.ResolvedDayAbs_MaxDelay = R(:,29);
        Twide.AUC_total_MinDelay      = R(:,30);
        Twide.AUC_total_MaxDelay      = R(:,31);
        Twide.CO2Total_MinDelay       = R(:,32);
        Twide.CO2Total_MaxDelay       = R(:,33);
        Twide.ErrFlag = errFlag;
        Twide.ErrMsg  = errMsg;
        return;
    end

    M = array2table(M_export, 'VariableNames', matlab.lang.makeValidName(cellstr(BASE_ELEM_NAMES)));

    Twide = table(configNum, 'VariableNames', {'ConfigNum'});
    Twide = [Twide, M];

    Twide.TotalComplexity         = R(:,15);
    Twide.ResolvedDayAbs          = R(:,16);
    Twide.TotalCost_MUSD          = R(:,18) / 1e6;
    Twide.AUC_total_acreDays      = R(:,21);
    Twide.CO2Total_MMT            = R(:,22);
    Twide.EO_MinObsGap_hr         = R(:,23);
    Twide.EO_MaxObsGap_hr         = R(:,24);
    Twide.Weather_MinObsGap_hr    = R(:,25);
    Twide.AllSat_MinObsGap_hr     = R(:,26);
    Twide.AllSat_MaxObsGap_hr     = R(:,27);
    Twide.ResolvedDayAbs_MinDelay = R(:,28);
    Twide.ResolvedDayAbs_MaxDelay = R(:,29);
    Twide.AUC_total_MinDelay      = R(:,30);
    Twide.AUC_total_MaxDelay      = R(:,31);
    Twide.CO2Total_MinDelay       = R(:,32);
    Twide.CO2Total_MaxDelay       = R(:,33);

    Twide.ErrFlag = errFlag;
    Twide.ErrMsg  = errMsg;
end

%EXPORT_NOW
% Exports the saved MAT results into an Excel workbook with summary and wide configuration sheets.
function export_now(matFile, outXlsx)
    if nargin < 1 || strlength(string(matFile))==0
        matFile = 'sweep_results_checkpoint.mat';
    end
    if nargin < 2 || strlength(string(outXlsx))==0
        outXlsx = 'sweep_results_detailed.xlsx';
    end
    if ~isfile(matFile)
        error("export_now: MAT file not found: %s", matFile);
    end

    S = load(matFile, 'R','errFlag','errMsg','BASE_ELEM_NAMES','M_export','USGov_plot');
    R = S.R;
    if size(R,2) < 33
        R(:,end+1:33) = NaN;
    end
    errFlag = S.errFlag;
    errMsg = S.errMsg;
    BASE_ELEM_NAMES = S.BASE_ELEM_NAMES;
    M_export = S.M_export;

    [Tsum, Twide] = build_tables(R, errFlag, errMsg, BASE_ELEM_NAMES, M_export);

    writetable(Tsum,  outXlsx, 'Sheet','Summary');
    writetable(Twide, outXlsx, 'Sheet','WideConfig');

    fprintf("Exported:\n  Summary   -> %s [Sheet: Summary]\n  WideConfig-> %s [Sheet: WideConfig]\n", outXlsx, outXlsx);

    assignin('base','T',Tsum);
    assignin('base','Twide',Twide);
    assignin('base','sweepTable',Tsum);
    assignin('base','sweepWideTable',Twide);
end

%GETFIELDANY
% Safely returns the first available field from a list of possible field names.
function val = getFieldAny(S, names, defaultVal)
    % Start with the default value and replace it only if a requested field exists.
    val = defaultVal;
    for i = 1:numel(names)
        fn = names{i};
        if isstruct(S) && isfield(S, fn)
            val = S.(fn);
            return;
        end
    end
end

%COMPUTE_OBS_METRICS_FROM_CFG
% Computes satellite observation gap metrics using the active satellite counts in cfg.
function obs = compute_obs_metrics_from_cfg(cfg, stkObs)
    % Initialize all observation metrics to NaN in case no satellites are active.
    obs = struct();
    obs.EO_MinObsGap_hr = NaN;
    obs.EO_MaxObsGap_hr = NaN;
    obs.Weather_MinObsGap_hr = NaN;
    obs.AllSat_MinObsGap_hr = NaN;
    obs.AllSat_MaxObsGap_hr = NaN;

    nEO = round(get_cfg_asset_count(cfg, 'EO Satellites (OroraTech)'));
    nW  = round(get_cfg_asset_count(cfg, 'Weather Satellites (GOES-16/GOES-18)'));

    nEO = max(0, min(nEO, numel(stkObs.eoNames)));
    nW  = max(0, min(nW,  numel(stkObs.weatherNames)));

    eoNames = stkObs.eoNames(1:nEO);
    wNames  = stkObs.weatherNames(1:nW);

    eoIntervals  = collect_intervals_from_cache(stkObs, eoNames);
    wIntervals   = collect_intervals_from_cache(stkObs, wNames);
    allIntervals = [eoIntervals; wIntervals];

    eoMerged  = merge_time_intervals(eoIntervals);
    wMerged   = merge_time_intervals(wIntervals);
    allMerged = merge_time_intervals(allIntervals);

    [obs.EO_MinObsGap_hr, obs.EO_MaxObsGap_hr] = observation_gap_stats_hours(eoMerged, stkObs.startStr, stkObs.stopStr);
    [obs.Weather_MinObsGap_hr, ~]              = observation_gap_stats_hours(wMerged,  stkObs.startStr, stkObs.stopStr);
    [obs.AllSat_MinObsGap_hr, obs.AllSat_MaxObsGap_hr] = observation_gap_stats_hours(allMerged, stkObs.startStr, stkObs.stopStr);
end

%GET_CFG_ASSET_COUNT
% Counts how many copies of a named asset are active in the configuration.
function n = get_cfg_asset_count(cfg, assetName)
    % Default to zero if the asset is not found.
    n = 0;

    if isfield(cfg,'elements_master') && isfield(cfg,'mult_master')
        names = string(cfg.elements_master(:));
        mults = cfg.mult_master(:);

        idx = strcmp(names, string(assetName));
        if any(idx)
            n = sum(mults(idx), 'omitnan');
            return;
        end
    end

    if isfield(cfg,'expandedElements')
        names = string(cfg.expandedElements(:));
        n = sum(strcmp(names, string(assetName)));
    end
end

%COLLECT_INTERVALS_FROM_CACHE
% Pulls access intervals for selected satellites from the STK observation cache.
function intervals = collect_intervals_from_cache(stkObs, satNames)
    % Start with an empty UTC datetime interval array.
    intervals = NaT(0,2,'TimeZone','UTC');

    for i = 1:numel(satNames)
        fld = matlab.lang.makeValidName(char(satNames(i)));
        if isfield(stkObs.intervals, fld)
            A = stkObs.intervals.(fld);
            if ~isempty(A)
                % Append this satellite's intervals to the combined interval list.
                intervals = [intervals; A];
            end
        end
    end
end

%MERGE_TIME_INTERVALS
% Merges overlapping access windows into continuous observation intervals.
function merged = merge_time_intervals(intervals)
    if isempty(intervals)
        merged = NaT(0,2,'TimeZone','UTC');
        return;
    end

    intervals = sortrows(intervals, 1);
    merged = intervals(1,:);

    for i = 2:size(intervals,1)
        s = intervals(i,1);
        e = intervals(i,2);

        lastE = merged(end,2);

        if s <= lastE
            merged(end,2) = max(lastE, e);
        else
            % Store the completed merged interval before starting a new one.
            merged = [merged; [s e]];
        end
    end
end

%PARETO_FRONT_MASK_MIN2
% Finds Pareto-efficient points when both plotted objectives should be minimized.
function isPareto = pareto_front_mask_min2(x, y)
    x = x(:);
    y = y(:);

    valid = isfinite(x) & isfinite(y);
    isPareto = false(size(x));

    if ~any(valid)
        return;
    end

    xv = x(valid);
    yv = y(valid);
    n  = numel(xv);

    keep = true(n,1);

    for i = 1:n
        if ~keep(i), continue; end

        dominated = (xv <= xv(i) & yv <= yv(i)) & ...
                    (xv <  xv(i) | yv <  yv(i));

        dominated(i) = false;

        if any(dominated)
            keep(i) = false;
        end
    end

    idxValid = find(valid);
    isPareto(idxValid(keep)) = true;
end

%OBSERVATION_GAP_STATS_HOURS
% Computes minimum and maximum gaps between satellite observation windows.
function [gMin, gMax] = observation_gap_stats_hours(mergedIntervals, startStr, stopStr)
    tStart = datetime(startStr, 'InputFormat','d MMM yyyy HH:mm:ss.SSS', 'TimeZone','UTC');
    tStop  = datetime(stopStr,  'InputFormat','d MMM yyyy HH:mm:ss.SSS', 'TimeZone','UTC');

    gMin = NaN;
    gMax = NaN;

    if isempty(mergedIntervals)
        return;
    end

    mergedIntervals = sortrows(mergedIntervals, 1);

    mergedIntervals(:,1) = max(mergedIntervals(:,1), tStart);
    mergedIntervals(:,2) = min(mergedIntervals(:,2), tStop);

    keep = mergedIntervals(:,2) >= mergedIntervals(:,1);
    mergedIntervals = mergedIntervals(keep,:);

    if isempty(mergedIntervals)
        return;
    end

    gapsHr = [];

    g0 = hours(mergedIntervals(1,1) - tStart);
    if g0 > 0
        % Add the gap from scenario start to the first observation interval.
        gapsHr(end+1,1) = g0;
    end

    for k = 1:size(mergedIntervals,1)-1
        gk = hours(mergedIntervals(k+1,1) - mergedIntervals(k,2));
        if gk > 0
            % Add the gap between consecutive observation intervals.
            gapsHr(end+1,1) = gk;
        end
    end

    gF = hours(tStop - mergedIntervals(end,2));
    if gF > 0
        % Add the gap from the final observation interval to scenario stop.
        gapsHr(end+1,1) = gF;
    end

    if isempty(gapsHr)
        gMin = 0;
        gMax = 0;
    else
        gMin = min(gapsHr);
        gMax = max(gapsHr);
    end
end