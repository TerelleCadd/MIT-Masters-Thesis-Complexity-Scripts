function out = simulate_fire_overlay_on_map(I_map, latGrid, lonGrid, latPoly, lonPoly, ignLat, ignLon, daysTotal, opts)
%SIMULATE_FIRE_OVERLAY_ON_MAP
%
% This function simulates wildfire spread over a map image using a
% deterministic spread-field approach. The fire begins at a specified
% ignition latitude/longitude and expands outward until it reaches a final
% known wildfire perimeter polygon at the specified final simulation day.
%
% The function converts geographic latitude/longitude inputs into image
% pixel coordinates, rasterizes the final perimeter into a mask, estimates
% meters per pixel from the latitude/longitude grid, builds a spatial cost
% field from map brightness/texture and optional elevation data, and then
% uses Dijkstra's shortest-path algorithm to compute a deterministic
% arrival/spread metric from the ignition point to all pixels.
%
% The spread field is then scaled so that the simulated burn mask reaches
% the known final perimeter at daysTotal. The function produces burn-area
% history, intermediate masks over time, deterministic spread-field
% visualizations, and an animation overlay showing the fire expanding on
% the original map.
%
% Inputs:
%   I_map      - Map image used as the visual/geographic background.
%   latGrid    - Latitude value for each pixel in the map image.
%   lonGrid    - Longitude value for each pixel in the map image.
%   latPoly    - Latitude coordinates of the final fire perimeter polygon.
%   lonPoly    - Longitude coordinates of the final fire perimeter polygon.
%   ignLat     - Ignition latitude.
%   ignLon     - Ignition longitude.
%   daysTotal  - Number of days until the simulated fire should match the
%                final perimeter.
%   opts       - Optional structure containing model and visualization
%                settings.
%
% Outputs:
%   out.maskAtTime     - Cell array containing burned masks at each time.
%   out.tHours         - Simulation time vector in hours.
%   out.areaAcresMask  - Burned area history computed from mask pixels.
%   out.targetAcres    - Final target area from the perimeter mask.
%   out.ignPix         - Ignition location in pixel coordinates [x y].
%   out.targetMask     - Rasterized final perimeter mask.
%   out.T              - Deterministic spread/travel metric field.
%   out.mpp            - Estimated meters per pixel.
%   out.areaAcres      - Alias for areaAcresMask.

% If the user does not provide an options structure, create an empty one.
% The fields below will then be filled with default values.
if nargin < 9, opts = struct(); end

% Define the wind direction used by the anisotropic spread model.
% This value follows meteorological convention: the direction wind comes FROM.
if ~isfield(opts,'windDirFromDeg'),   opts.windDirFromDeg = 45; end

% Define how strongly the wind biases the spread direction.
% A value of 1 would mean no wind-direction preference.
if ~isfield(opts,'anisotropy'),       opts.anisotropy = 2.0; end

% Define the spacing between saved animation frames, in hours.
if ~isfield(opts,'frameStepHours'),   opts.frameStepHours = 6; end

% Define transparency for the red burn overlay in the animation.
if ~isfield(opts,'alpha'),            opts.alpha = 0.35; end

% Decide whether the map image should be used to estimate a moisture/dryness
% proxy. This is a simplified way to let visual map features affect spread.
if ~isfield(opts,'useMoisture'),      opts.useMoisture = true; end

% Decide whether elevation effects should be included in the spread cost.
if ~isfield(opts,'useElevation'),     opts.useElevation = false; end

% Weight applied to the image-derived moisture/wetness cost.
% Larger values make wet-looking regions more resistant to spread.
if ~isfield(opts,'moistureWeight'),   opts.moistureWeight = 1.5; end

% Weight applied to slope effects if elevation is enabled.
if ~isfield(opts,'slopeWeight'),      opts.slopeWeight = 2.0; end

% Elevation grid used only if opts.useElevation is true.
if ~isfield(opts,'elevGrid'),         opts.elevGrid = []; end

% Optional visual randomness that breaks up the burn mask.
% This is for visualization only and does not change the core deterministic
% spread field.
if ~isfield(opts,'patchiness'),       opts.patchiness = 0; end

% Toggle for the normalized deterministic spread-field heatmap.
if ~isfield(opts,'makeTfieldHeatmap'), opts.makeTfieldHeatmap = true; end

% Toggle for the deterministic spread-field contour plot.
if ~isfield(opts,'makeTfieldContours'), opts.makeTfieldContours = true; end

% Transparency for the spread-field heatmap overlay.
if ~isfield(opts,'tfieldAlpha'), opts.tfieldAlpha = 0.45; end

% Number of contour levels to draw for the deterministic spread field.
if ~isfield(opts,'nContourLevels'), opts.nContourLevels = 6; end

% Define the default time-varying fire spread schedule if the user does not
% provide one. Each row is [ending time in hours, speed in meters/second].
% This schedule produces rapid early growth followed by slower later growth.
if ~isfield(opts,'rateSchedule')
    opts.rateSchedule = [
        4,      5.0;
        12,     1.5;
        48,     0.4;
        24*daysTotal, 0.1
    ];
end

% Store the map image dimensions.
% H is the number of image rows and W is the number of image columns.
H = size(I_map,1);
W = size(I_map,2);

% Convert the final perimeter polygon from latitude/longitude coordinates
% into map pixel coordinates.
[xPoly, yPoly] = latlon_to_pixel(latPoly, lonPoly, latGrid, lonGrid);

% Rasterize the final perimeter polygon into a binary mask.
% Pixels inside the final perimeter are true; pixels outside are false.
targetMask = poly2mask(xPoly, yPoly, H, W);

% Convert the ignition latitude/longitude into pixel coordinates.
[xIgn, yIgn] = latlon_to_pixel(ignLat, ignLon, latGrid, lonGrid);

% Round the ignition pixel to integer image coordinates and keep it away
% from the exact image boundary to avoid neighbor-indexing issues later.
xIgn = max(2, min(W-1, round(xIgn)));
yIgn = max(2, min(H-1, round(yIgn)));

% Estimate the horizontal pixel spacing in meters near the ignition point.
% This uses the distance between the ignition pixel and the pixel one column
% to the right.
dx_m = local_meters_between(latGrid(yIgn,xIgn), lonGrid(yIgn,xIgn), ...
                            latGrid(yIgn,xIgn), lonGrid(yIgn,min(W,xIgn+1)));

% Estimate the vertical pixel spacing in meters near the ignition point.
% This uses the distance between the ignition pixel and the pixel one row
% below it.
dy_m = local_meters_between(latGrid(yIgn,xIgn), lonGrid(yIgn,xIgn), ...
                            latGrid(min(H,yIgn+1),xIgn), lonGrid(min(H,yIgn+1),xIgn));

% Use the mean of horizontal and vertical spacing as the representative
% meters-per-pixel value.
mpp = mean([dx_m, dy_m]);

% Stop execution if the meters-per-pixel estimate is invalid.
if ~isfinite(mpp) || mpp <= 0
    error("Could not estimate meters-per-pixel from lat/lon grids.");
end

% Convert one pixel of area into acres.
% Each pixel covers approximately mpp^2 square meters.
acrePerPixel = (mpp^2) * 0.000247105381;

% Initialize the moisture/dryness cost field to ones.
% A cost of 1 means neutral spread resistance.
moistCost = ones(H,W);

% Build an image-based moisture/wetness proxy if enabled.
% The goal is not to model vegetation physics directly, but to create a
% spatial resistance field from the map image.
if opts.useMoisture

    % Convert the map image to grayscale double precision.
    % Brighter/darker image regions are used as rough visual proxies.
    Ig = im2double(im2gray(I_map));

    % Blur the grayscale image to capture broad spatial brightness trends.
    Ig_blur  = imgaussfilt(Ig, 6);

    % Treat darker blurred regions as wetter or more resistant areas.
    wet_dark = 1 - mat2gray(Ig_blur);

    % Compute image gradients to estimate local texture/ruggedness.
    [Gx, Gy] = imgradientxy(Ig);
    gradmag = hypot(Gx, Gy);

    % Smooth and normalize the gradient magnitude.
    rugged = mat2gray(imgaussfilt(gradmag, 2));

    % Combine darkness and smoothness into a wetness proxy.
    % The first term emphasizes dark regions, while the second term gives
    % higher wetness to smoother and less rugged areas.
    wetness = 0.70*wet_dark + 0.30*(1 - rugged);

    % Clamp the wetness proxy to the valid range [0, 1].
    wetness = min(max(wetness,0),1);

    % Convert wetness into a multiplicative spread cost.
    % Higher wetness produces higher resistance to fire spread.
    moistCost = exp(opts.moistureWeight * wetness);

    % Clamp the cost field to avoid extreme values dominating the solution.
    moistCost = min(max(moistCost, 0.6), 3.0);
end

% Initialize the elevation grid as empty.
elev = [];

% If elevation is enabled, load and validate the elevation grid.
if opts.useElevation

    % Pull elevation data from the options structure.
    elev = opts.elevGrid;

    % If elevation was requested but no grid was provided, disable elevation
    % effects and issue a warning.
    if isempty(elev)
        warning("opts.useElevation=true but opts.elevGrid empty. Disabling elevation effect.");
        opts.useElevation = false;
    else

        % Resize the elevation grid if it does not match the map dimensions.
        % This ensures each map pixel has a corresponding elevation value.
        if ~isequal(size(elev,1),H) || ~isequal(size(elev,2),W)
            elev = imresize(elev, [H W], "bilinear");
        end
    end
end

% Convert meteorological wind direction into the direction the wind moves TO.
% Meteorological wind direction is the direction wind comes FROM, so 180
% degrees is added.
dirTo = mod(opts.windDirFromDeg + 180, 360);

% Convert the wind direction into an image-coordinate unit vector.
% In image coordinates, +x is east/right and +y is south/down.
wx = sind(dirTo);
wy = -cosd(dirTo);

% Normalize the wind vector.
wn = hypot(wx, wy);
wx = wx / wn;
wy = wy / wn;

% Compute the deterministic travel/spread field from the ignition point.
% Lower Tfield values are reached earlier by the spreading fire.
Tfield = dijkstra_travel_time(moistCost, xIgn, yIgn, mpp, wx, wy, opts.anisotropy, elev, opts);

% Define the simulation end time in hours.
Tend_hours = daysTotal * 24;

% Create the simulation time vector from 0 to the final day.
tHours = 0:opts.frameStepHours:Tend_hours;

% Ensure that the rate schedule extends to the final simulation time.
% If not, append a final row using the last provided spread speed.
if opts.rateSchedule(end,1) < Tend_hours
    opts.rateSchedule(end+1,:) = [Tend_hours, opts.rateSchedule(end,2)];
end

% Compute the unscaled cumulative distance budget at each saved time.
% This represents how far the fire could travel based on the rate schedule.
DmBase = cumulative_distance_budget(tHours, opts.rateSchedule);

% Extract deterministic spread-field values only inside the final perimeter.
Tin = Tfield(targetMask);

% Keep only finite values inside the target perimeter.
Tin = Tin(isfinite(Tin));

% Determine the largest spread-field value that must be reached to cover
% the final perimeter.
tauEndNeeded = max(Tin);

% Scale the cumulative distance budget so that the fire reaches the full
% perimeter exactly at the final simulation time.
scale = tauEndNeeded / max(DmBase(end), 1e-9);
DmBase = DmBase * scale;

% Allocate a cell array to store the burned mask at each time.
maskAtTime = cell(numel(tHours),1);

% Allocate an area history vector in acres.
areaAcresMask = zeros(numel(tHours),1);

% Loop through each saved time and generate the corresponding burn mask.
for i = 1:numel(tHours)

    % The deterministic core burn includes pixels whose spread-field value
    % has been reached by the current cumulative distance budget.
    % The mask is also constrained to the final perimeter.
    maskCore = (Tfield <= DmBase(i)) & targetMask;

    % Start from the deterministic core mask.
    mask = maskCore;

    % Optional patchiness can be applied to make the visualization appear
    % less perfectly smooth. This does not change the underlying spread
    % field and should be interpreted as a display effect.
    if opts.patchiness > 0

        % Convert moisture cost into a probability of burning.
        % Higher resistance areas are less likely to appear burned.
        pBurn = exp(-opts.patchiness * (moistCost - 1));

        % Clamp probability values to a reasonable range.
        pBurn = min(max(pBurn, 0.05), 1.0);

        % Randomly thin the mask based on the burn probability.
        mask = mask & (rand(size(mask)) < pBurn);

        % Clean isolated pixels and fill small gaps.
        mask = imopen(mask, strel('disk', 1));
        mask = imclose(mask, strel('disk', 2));
    end

    % Store the mask for this time step.
    maskAtTime{i} = mask;

    % Convert the number of burned pixels into burned acres.
    areaAcresMask(i) = nnz(mask) * acrePerPixel;
end

% Compute the target final fire area from the rasterized perimeter mask.
targetAcres = nnz(targetMask) * acrePerPixel;

% Store the time-varying burn masks.
out.maskAtTime = maskAtTime;

% Store the simulation time vector.
out.tHours = tHours;

% Store the burn-area history from mask pixels.
out.areaAcresMask = areaAcresMask;

% Store the final target area.
out.targetAcres = targetAcres;

% Store the ignition pixel location.
out.ignPix = [xIgn yIgn];

% Store the final perimeter mask.
out.targetMask = targetMask;

% Store the deterministic spread field.
out.T = Tfield;

% Store the meters-per-pixel estimate.
out.mpp = mpp;

% Store an alias for the burn-area history.
out.areaAcres = areaAcresMask;

% Create a visualization copy of the spread field.
Tvis = Tfield;

% Hide spread-field values outside the final perimeter.
Tvis(~targetMask) = NaN;

% Extract finite values for normalization and plotting.
finiteT = Tvis(isfinite(Tvis));

% Only make spread-field visualizations if valid values exist.
if ~isempty(finiteT)

    % Normalize the spread field between 0 and 1 for visualization.
    % Lower values correspond to earlier arrival from the ignition point.
    Tnorm = (Tvis - min(finiteT)) ./ max(max(finiteT) - min(finiteT), eps);

    % Create the semi-transparent deterministic spread-field heatmap.
    if opts.makeTfieldHeatmap

        % Create a new figure for the heatmap.
        figT = figure('Name','Deterministic Spread Field Heatmap','Color','w');

        % Create axes inside the figure.
        axT = axes(figT); %#ok<LAXES>

        % Display the original map image as the background.
        imshow(I_map, 'Parent', axT);
        hold(axT,'on');

        % Overlay the normalized spread field on top of the map.
        hT = imagesc(axT, Tnorm);

        % Use transparency so the map is still visible beneath the heatmap.
        % The heatmap is only shown inside the final perimeter.
        set(hT, 'AlphaData', opts.tfieldAlpha * double(targetMask & isfinite(Tnorm)));

        % Use a high-contrast colormap for the normalized spread metric.
        colormap(axT, turbo);

        % Add a colorbar explaining the normalized arrival metric.
        cb = colorbar(axT);
        cb.Label.String = 'Normalized Deterministic Arrival Metric';
        cb.Label.Interpreter = 'latex';
        cb.TickLabelInterpreter = 'latex';

        % Plot the final perimeter outline in yellow.
        plot(axT, xPoly, yPoly, '-', 'Color', [1 0.9 0], 'LineWidth', 2.0);

        % Plot the ignition point.
        plot(axT, xIgn, yIgn, 'wo', ...
            'MarkerFaceColor', [0.85 0.1 0.1], ...
            'MarkerEdgeColor', 'k', ...
            'MarkerSize', 8);

        % Add the figure title.
        title(axT, 'Deterministic Spread Field Heat Map', ...
            'Interpreter','latex', 'FontSize', 16);

        % Apply thesis-style formatting to the axes.
        set(axT, 'FontName', 'Times', 'FontSize', 12, ...
            'TickLabelInterpreter','latex', 'LineWidth', 1.0);
    end

    % Create the deterministic spread-field contour plot.
    if opts.makeTfieldContours

        % Create a new figure for the contour visualization.
        figC = figure('Name','Deterministic Cost Field Contours','Color','w');

        % Create axes inside the figure.
        axC = axes(figC); %#ok<LAXES>

        % Display the original map image as the background.
        imshow(I_map, 'Parent', axC);
        hold(axC,'on');

        % Add a faint normalized spread-field background.
        hBase = imagesc(axC, Tnorm);

        % Keep the background transparent and only visible inside perimeter.
        set(hBase, 'AlphaData', 0.18 * double(targetMask & isfinite(Tnorm)));

        % Use a colormap for the faint background layer.
        colormap(axC, parula);

        % Create a contour copy of the spread field.
        Tcont = Tfield;

        % Hide values outside the final perimeter.
        Tcont(~targetMask) = NaN;

        % Define contour levels between the minimum and maximum finite
        % spread-field values. The extreme min/max levels are removed so
        % the plotted contours are easier to read.
        tLevels = linspace(min(finiteT), max(finiteT), opts.nContourLevels + 2);
        tLevels = tLevels(2:end-1);

        % Draw contour lines of the deterministic spread field.
        [C,hContour] = contour(axC, Tcont, tLevels, ...
            'LineColor', 'w', 'LineWidth', 1.4);

        % Add labels to the contour lines.
        clabel(C, hContour, 'Color', 'w', 'FontSize', 9, ...
            'Interpreter', 'latex', 'LabelSpacing', 350);

        % Plot the final perimeter outline in yellow.
        plot(axC, xPoly, yPoly, '-', 'Color', [1 0.9 0], 'LineWidth', 2.0);

        % Plot the ignition point.
        plot(axC, xIgn, yIgn, 'wo', ...
            'MarkerFaceColor', [0.85 0.1 0.1], ...
            'MarkerEdgeColor', 'k', ...
            'MarkerSize', 8);

        % Add the figure title.
        title(axC, 'Contours of Deterministic Spread Field', ...
            'Interpreter','latex', 'FontSize', 16);

        % Apply thesis-style formatting to the axes.
        set(axC, 'FontName', 'Times', 'FontSize', 12, ...
            'TickLabelInterpreter','latex', 'LineWidth', 1.0);
    end
end

% Create a figure showing burned area as a function of time.
figure('Name','Burn Area vs. Time','Color','w');

% Plot burned acres versus time in days.
plot(tHours/24, areaAcresMask, 'LineWidth', 2.5);

% Turn on the grid and plot box.
grid on;
box on;

% Label the x-axis.
xlabel('Time [Days]','FontSize',12);

% Label the y-axis.
ylabel('Burn Area [Acres]','FontSize',12);

% Add the plot title.
title('Burn Area vs. Time', 'FontSize', 13);

% Mark the final calibration day where the simulation reaches the final
% known perimeter.
xline(daysTotal, '--k', sprintf('Day %d (perimeter match)', daysTotal), ...
    'LabelVerticalAlignment','bottom', 'LabelHorizontalAlignment','left');

% Mark the final target area from the perimeter mask.
yline(targetAcres, '--', 'Target final acres', 'LabelHorizontalAlignment','left');

% Set the x-axis range from day 0 to the final simulated day.
xlim([0 max(tHours)/24]);

% Set the y-axis range slightly above the largest simulated burn area.
ylim([0 1.05*max(areaAcresMask)]);

% Set axis font size.
set(gca,'FontSize',11);

% Create the animation figure showing fire spread over the map.
figAnim = figure('Name','Fire Spread (Animation - maskAtTime)','Color','w');

% Create axes for the animation.
ax = axes(figAnim); %#ok<LAXES>

% Display the original map image.
imshow(I_map, 'Parent', ax);
hold(ax, 'on');

% Plot the final perimeter outline in yellow.
plot(ax, xPoly, yPoly, 'y-', 'LineWidth', 2);

% Create a red RGB image that will be used as the burn overlay.
% The overlay color is constant red, while transparency changes over time.
redOverlay = zeros(H,W,3, 'uint8');
redOverlay(:,:,1) = 255;

% Display the red overlay image on top of the map.
hOverlay = imshow(redOverlay, 'Parent', ax);

% Start with the overlay fully transparent.
set(hOverlay, 'AlphaData', zeros(H,W));

% Loop through each saved burn mask and update the animation overlay.
for i = 1:numel(maskAtTime)

    % Retrieve the burn mask for this time step.
    m = maskAtTime{i};

    % Make burned pixels visible by assigning them nonzero transparency.
    set(hOverlay, 'AlphaData', opts.alpha * double(m));

    % Update the animation title with the current frame number.
    title(ax, sprintf('Fire Spread Animation (%d/%d)', i, numel(maskAtTime)), ...
        'FontSize', 16, 'FontWeight','bold');

    % Force MATLAB to update the figure window immediately.
    drawnow;
end

end

%% ---------- helpers ----------

function [xPix, yPix] = latlon_to_pixel(latQ, lonQ, latGrid, lonGrid)
%LATLON_TO_PIXEL
%
% Converts one or more latitude/longitude query points into the nearest
% pixel coordinates on the provided latitude/longitude grids.
%
% This function performs a nearest-neighbor search over the latitude and
% longitude values associated with each map pixel.

% Get the latitude grid dimensions.
H = size(latGrid,1);
W = size(latGrid,2);

% Allocate output arrays with the same size as the query latitude input.
xPix = zeros(size(latQ));
yPix = zeros(size(latQ));

% Flatten the latitude and longitude grids so that each pixel can be
% searched as a single list entry.
latV = latGrid(:);
lonV = lonGrid(:);

% Loop through every query point.
for k = 1:numel(latQ)

    % Compute squared distance in latitude/longitude space from the query
    % point to every map pixel.
    d = (latV - latQ(k)).^2 + (lonV - lonQ(k)).^2;

    % Find the pixel with the smallest squared distance.
    [~, idx] = min(d);

    % Convert the linear index back into row and column image coordinates.
    [r,c] = ind2sub([H,W], idx);

    % Return x as the image column and y as the image row.
    yPix(k) = r;
    xPix(k) = c;
end

end

function d = local_meters_between(lat1, lon1, lat2, lon2)
%LOCAL_METERS_BETWEEN
%
% Computes the approximate great-circle distance in meters between two
% latitude/longitude points using the haversine formula.

% Mean Earth radius in meters.
R = 6371000;

% Convert latitudes from degrees to radians.
phi1 = deg2rad(lat1);
phi2 = deg2rad(lat2);

% Compute latitude and longitude differences in radians.
dphi = deg2rad(lat2-lat1);
dl = deg2rad(lon2-lon1);

% Haversine formula intermediate term.
a = sin(dphi/2).^2 + cos(phi1).*cos(phi2).*sin(dl/2).^2;

% Convert the angular distance into meters.
d = 2*R*atan2(sqrt(a), sqrt(1-a));

end

function Dm = cumulative_distance_budget(tHours, rateSchedule)
%CUMULATIVE_DISTANCE_BUDGET
%
% Computes the cumulative spread distance at each requested time by
% integrating the piecewise fire spread-rate schedule.

% Allocate output vector.
Dm = zeros(size(tHours));

% Evaluate the cumulative distance at each time point.
for k = 1:numel(tHours)
    Dm(k) = integrate_schedule_to_time(tHours(k), rateSchedule);
end

end

function D = integrate_schedule_to_time(t, rateSchedule)
%INTEGRATE_SCHEDULE_TO_TIME
%
% Integrates the piecewise spread-rate schedule from time 0 to time t.
% The schedule is given in hours and meters per second, so each segment is
% converted to meters by multiplying by 3600 seconds/hour.

% Initialize cumulative distance.
D = 0;

% Starting time of the current schedule segment.
t0 = 0;

% Loop through each row of the rate schedule.
for r = 1:size(rateSchedule,1)

    % End time of this schedule segment, in hours.
    tEnd = rateSchedule(r,1);

    % Spread speed during this segment, in meters per second.
    v = rateSchedule(r,2);

    % If the requested time is before the current segment starts, stop.
    if t <= t0
        break;
    end

    % Compute how many hours of this segment should be included.
    dt = min(t, tEnd) - t0;

    % Add this segment's distance contribution.
    if dt > 0
        D = D + v * dt * 3600;
    end

    % Move the segment start time forward.
    t0 = tEnd;

    % If the requested time falls within this segment, integration is done.
    if t <= tEnd
        break;
    end
end

end

function T = dijkstra_travel_time(cost, x0, y0, mpp, wx, wy, anis, elev, opts)
%DIJKSTRA_TRAVEL_TIME
%
% Computes a deterministic spread/travel field from the ignition pixel using
% Dijkstra's shortest-path algorithm.
%
% Each pixel is treated as a node in a grid graph. Moving from one pixel to
% a neighboring pixel has a cost based on pixel distance, the local
% moisture/dryness cost, wind direction, and optional slope effects. The
% output T gives the minimum accumulated travel cost needed to reach every
% pixel from the ignition location.

% Get the size of the cost grid.
[H,W] = size(cost);

% Define a very large value used as the initial unreached distance.
INF = 1e18;

% Initialize all travel costs to infinity.
T = INF*ones(H,W);

% Set the ignition pixel travel cost to zero.
T(y0,x0) = 0;

% Track which pixels have already been finalized.
visited = false(H,W);

% Initialize the active queue with the ignition pixel.
Qx = x0;
Qy = y0;

% Define the 8-connected neighbor offsets.
% This allows the fire to spread horizontally, vertically, and diagonally.
nbr = [-1 -1; -1 0; -1 1; 0 -1; 0 1; 1 -1; 1 0; 1 1];

% Ensure anisotropy is at least 1.
% Values above 1 favor spread in the downwind direction.
anis = max(1.0, anis);

% Continue until there are no more active pixels to process.
while ~isempty(Qx)

    % Find the queued pixel with the smallest current travel cost.
    % This is the basic Dijkstra selection step.
    idxMin = 1;
    tMin = T(Qy(1),Qx(1));

    for i=2:numel(Qx)
        tv = T(Qy(i),Qx(i));
        if tv < tMin
            tMin = tv;
            idxMin = i;
        end
    end

    % Remove the minimum-cost pixel from the queue.
    x = Qx(idxMin);
    y = Qy(idxMin);
    Qx(idxMin) = [];
    Qy(idxMin) = [];

    % Skip this pixel if it has already been finalized.
    if visited(y,x), continue; end

    % Mark this pixel as finalized.
    visited(y,x) = true;

    % Loop through each neighboring pixel.
    for k=1:8

        % Candidate neighbor row and column.
        yy = y + nbr(k,1);
        xx = x + nbr(k,2);

        % Skip neighbors outside the image bounds.
        if xx<1 || xx>W || yy<1 || yy>H, continue; end

        % Skip neighbors that have already been finalized.
        if visited(yy,xx), continue; end

        % Get the row/column step direction.
        step = nbr(k,:);

        % Convert the pixel step into a physical distance.
        % Diagonal moves are longer than horizontal or vertical moves.
        dist = mpp * norm(step);

        % Convert the image step into an x/y movement vector.
        % step(2) corresponds to x movement and step(1) corresponds to y.
        mv = [step(2), step(1)];

        % Normalize the movement vector.
        mv = mv / max(norm(mv),1e-9);

        % Compute alignment between the movement direction and wind direction.
        % Positive values mean the movement is downwind.
        dotw = mv(1)*wx + mv(2)*wy;

        % Reduce cost for downwind movement according to the anisotropy value.
        % Crosswind or upwind movement is not given the same benefit.
        dirFactor = exp(-log(anis) * max(dotw,0));

        % Combine local terrain/image cost with wind-direction effect.
        wcost = cost(yy,xx) * dirFactor;

        % Include elevation effects if enabled.
        if opts.useElevation

            % Compute elevation change from the current pixel to the neighbor.
            dz = elev(yy,xx) - elev(y,x);

            % Estimate slope over the movement distance.
            slope = dz / max(dist, 1e-9);

            % Convert slope into a multiplicative factor.
            % This simplified formulation modifies the spread cost based on
            % uphill/downhill movement.
            slopeFactor = exp(-opts.slopeWeight * slope);

            % Clamp the slope factor to avoid extreme behavior.
            slopeFactor = min(max(slopeFactor, 0.4), 2.5);

            % Apply the slope factor to the movement cost.
            wcost = wcost * slopeFactor;
        end

        % Candidate travel cost to reach the neighbor through this pixel.
        cand = T(y,x) + dist * wcost;

        % If this path is better than the previous best path to the neighbor,
        % update the travel field and add the neighbor to the active queue.
        if cand < T(yy,xx)
            T(yy,xx) = cand;
            Qx(end+1) = xx; 
            Qy(end+1) = yy; 
        end
    end
end

% Keep unreachable/nonfinite pixels at the large INF value.
T(~isfinite(T)) = INF;

end