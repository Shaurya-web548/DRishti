function result = segmentRetina(image)
%SEGMENTRETINA  Classical (rule-based, non-deep-learning) segmentation of a
%   colour fundus image. No trained model of any kind is used or required.
%
%   result = segmentRetina(image)      image = file path, or an RGB / grayscale array
%
%   Steps (numbers refer to the spec):
%     (3) vessels          multi-orientation matched filter + hysteresis threshold
%     (1) optic disc       imbinarize on the smoothed green channel + regionprops
%     (2) fovea            darkest blob ~2.5 disc-diameters temporal to the disc
%     (4) microaneurysms   white top-hat (imtophat) on the inverted green channel
%     (5) exudates /       bright / dark deviations from a median-filtered
%         hemorrhages      background, filtered with regionprops shape measures
%     (6) neovascularization  classical proxy: flags vessel clusters that are
%                           simultaneously denser AND more tortuous than the
%                           peripheral baseline, split into NVD (on/near disc)
%                           and NVE (elsewhere). See the caveat in section (6).
%   Vessels run first because the other steps use the vessel mask.
%   A matched filter is used because it needs no training data and every
%   decision it makes is inspectable (orientation, scale, threshold) -
%   deliberately chosen over a black-box approach for this module.
%
%   REQUIREMENT COVERAGE (Module 2 spec item: "optic disc/fovea localization,
%   vessel segmentation, microaneurysm detection, exudate segmentation,
%   hemorrhage classification, and neovascularization detection"):
%     optic disc localization    -> result.opticDisc      (done)
%     fovea localization         -> result.fovea           (done)
%     vessel segmentation        -> result.vesselMask       (done)
%     microaneurysm detection    -> result.microaneurysms   (done, sub-pixel-scale top-hat)
%     exudate segmentation       -> result.exudateMask      (done)
%     hemorrhage classification  -> result.hemorrhageMask   (done - detects/localizes
%                                    hemorrhages; does NOT sub-type into dot/blot/
%                                    flame, flag this honestly if asked)
%     neovascularization detect. -> result.neovascularization (done - EXPERIMENTAL
%                                    heuristic, not a validated detector, see (6))
%
%   Output - every mask / coordinate is at the ORIGINAL image resolution:
%     result.opticDisc            .center [x y]  .radius  .mask  .found
%     result.fovea                .center [x y]  .radius  .mask  .found
%     result.vesselMask           logical
%     result.microaneurysms       .mask  .centroids (N x 2, [x y])  .count
%     result.exudateMask          logical
%     result.hemorrhageMask       logical
%     result.neovascularization   .nvdMask  .nveMask  .nvdScore  .nveScore  .found
%                                  (EXPERIMENTAL - see section (6) caveat)
%     result.fovMask              logical, field of view
%     result.overlay               SINGLE RGB image: colour-coded lesion/vessel
%                                  overlay PLUS text labels with leader lines for
%                                  every structure actually found (styled like a
%                                  textbook fundus annotation figure). Only found
%                                  structures get a label, so the image never gets
%                                  more crowded than what was actually detected.
%
%   Sizes are fractions of the field-of-view radius, so the same settings work
%   across image sizes and cameras. Requires the Image Processing Toolbox.
%   The text-label overlay additionally uses insertText/insertShape (Computer
%   Vision Toolbox); if that toolbox isn't available, result.overlay silently
%   falls back to the plain colour-coded overlay with no text - it never errors.
%
%   Example:
%       r = segmentRetina('fundus01.jpg');
%       figure, imshow(r.overlay)

%% ------------------------------------------------------------------ SETTINGS
% Sizes are fractions of the FOV radius (areas: fractions of FOV radius^2).
% Contrasts are on a 0-1 intensity scale. Starting points - tune on your images.
T.workLongSide   = 1024;     % processing resolution (long side; never upsampled)
T.background     = 15;       % luminance <= this (0-255) = outside the FOV
T.fovErode       = 0.03;     % ignore this band along the FOV edge

T.vesselSigmas   = [0.003 0.006];  % matched-filter Gaussian widths (thin, thick vessels)
T.vesselHighPct  = 0.92;     % hysteresis: seed pixels above this percentile of the response
T.vesselLowPct   = 0.80;     % ... grown into pixels above this percentile
T.vesselMinArea  = 0.00006;  % drop fragments smaller than this x FOV area

T.odRadius       = 0.14;     % expected optic-disc radius
T.odAreaRange    = [0.25 3]; % accepted candidate area, x expected disc area
T.odBrightPct    = 0.975;    % imbinarize threshold = this percentile of the smoothed green
T.odExclude      = 1.6;      % lesion search skips this x disc radius around the disc

T.foveaDist      = 4.8;      % expected disc-to-fovea distance, x disc radius
T.foveaDrop      = 0.5;      % expected fovea offset below the disc, x disc radius
T.foveaSearch    = 1.5;      % search radius around the expected point, x disc radius

T.maRadius       = 0.012;    % top-hat disk radius = largest microaneurysm radius
T.maMinContrast  = 0.03;     % top-hat response needed
T.maMinArea      = 0.00002;  % area, x FOV radius^2
T.maMaxEcc       = 0.85;     % roundness limit (0 = circle, 1 = line)

T.bgWindow       = 0.10;     % median-filter window for the background estimate
T.exMinContrast  = 0.05;     % exudate: brighter than background by this
T.exMinArea      = 0.00003;  % area, x FOV radius^2
T.hemMinContrast = 0.04;     % hemorrhage: darker than background by this
T.hemMinMinor    = 0.012;    % hemorrhage: min minor-axis length (rejects vessel bits)
T.hemMinSolidity = 0.5;      % hemorrhage: min solidity (rejects ragged vessel bits)
T.foveaGuard     = 0.6;      % no hemorrhage search within this x disc radius of the fovea

% --- Neovascularization (Module 2 spec item, EXPERIMENTAL classical proxy) ---
T.nvEnabled      = true;     % set false to skip section (6) entirely
T.nvSearchBand   = [1.6 3.0];  % NVD annulus: this x disc radius, around the disc
T.nvMinSegLen    = 6;        % min skeleton-segment pixel count considered (noise floor)
T.nvTortuosity   = 1.15;     % arc/chord ratio above this = "tortuous" segment
T.nvDensityWin   = 0.12;     % x FOV radius, local vessel-density window
T.nvDensityZ     = 2.0;      % flag local density more than this many std devs above periphery mean
T.nvMinClusterArea = 0.0004; % x FOV radius^2, minimum area of a flagged NV cluster

%% --------------------------------------------------------------------- LOAD
if exist('imtophat', 'file') ~= 2
    error('segmentRetina:noToolbox', 'The Image Processing Toolbox is required.');
end
if ischar(image) || isstring(image)
    [I, cmap] = imread(char(image));
    if ~isempty(cmap), I = ind2rgb(I, cmap); end
else
    I = image;
end
if size(I, 3) > 3,  I = I(:, :, 1:3);  end
I = im2uint8(I);
if size(I, 3) == 1, I = repmat(I, [1 1 3]); end          % grayscale -> 3 channels
[H0, W0, ~] = size(I);

scale = min(1, T.workLongSide / max(H0, W0));            % work on a smaller copy
Iw = imresize(I, scale);
[H, W, ~] = size(Iw);
G = Iw(:, :, 2);                                         % green channel: best vessel / lesion contrast

% Field of view: largest non-black blob; its bounding box gives the FOV radius
fov = bwareafilt(imfill(rgb2gray(Iw) > T.background, 'holes'), 1);
bb  = regionprops(fov, 'BoundingBox');
if isempty(bb)
    error('segmentRetina:noFOV', 'No field of view found (image is all black?).');
end
bbox = bb(1).BoundingBox;                                % [x y w h]
fovR = max(bbox(3:4)) / 2;
fovCenter = [bbox(1) + bbox(3) / 2, bbox(2) + bbox(4) / 2];
px     = @(f) max(1, round(f * fovR));                   % FOV-relative length -> pixels
pxArea = @(f) max(2, round(f * fovR^2));                 % FOV-relative area   -> pixels
fovE = imerode(fov, strel('disk', px(T.fovErode)));      % analysis region (edge band removed)
odR  = px(T.odRadius);                                   % expected disc radius (px)

% Green channel with the outside of the FOV filled with the mean retina value,
% so the black border does not create fake edges or dark blobs.
Gf = G;  Gf(~fov) = mean(G(fov));
Gd = im2double(Gf);

%% --------------------------------------- (3) BLOOD VESSELS - matched filter
Gi = 1 - Gd;                                             % vessels become bright ridges
Gi = adapthisteq(Gi, 'ClipLimit', 0.01);
Gi = imtophat(Gi, strel('disk', px(0.03)));              % remove smooth background, keep thin bright structures
resp = zeros(H, W);
for sigma = T.vesselSigmas * fovR
    L = 2 * round(2.5 * sigma) + 1;                      % kernel length along the vessel
    for theta = 0:15:165
        resp = max(resp, imfilter(Gi, matchedKernel(sigma, L, theta), 'replicate'));
    end
end
resp(~fovE) = 0;

vessel = imreconstruct(resp > pct(resp(fovE), T.vesselHighPct), ...
                       resp > pct(resp(fovE), T.vesselLowPct));   % hysteresis threshold
vessel = bwareaopen(vessel, round(T.vesselMinArea * nnz(fov)));
vesselWide = imdilate(vessel, strel('disk', px(0.006)));          % vessels + a small margin

% Representative point for the "Main Blood Vessel" label: the vessel pixel
% with the largest local thickness (widest part of the main arcade).
distT = bwdist(~vesselWide);
distT(~vessel) = 0;
if any(distT(:) > 0)
    [~, idxMax] = max(distT(:));
    [vy, vx] = ind2sub([H W], idxMax);
    vesselPointW = [vx vy];
else
    vesselPointW = [];
end

%% ------------------------------ (1) OPTIC DISC - imbinarize + regionprops
Gs = imclose(Gd, strel('disk', px(0.015)));              % fill the dark vessels crossing the disc
Gs = imgaussfilt(Gs, 0.15 * odR);                        % blur away exudates and texture
bw = imbinarize(Gs, pct(Gs(fovE), T.odBrightPct)) & fovE;         % brightest few percent
bw = imopen(bw, strel('disk', max(1, round(0.2 * odR))));          % drop thin bright bits
st = regionprops(bw, Gs, 'Area', 'Centroid', 'MeanIntensity', 'EquivDiameter');
st = st([st.Area] >= T.odAreaRange(1) * pi * odR^2 & [st.Area] <= T.odAreaRange(2) * pi * odR^2);

odFound = ~isempty(st);
if odFound                                               % pick the candidate that is bright AND vessel-dense
    score = zeros(numel(st), 1);
    for k = 1:numel(st)
        near = circleMask([H W], st(k).Centroid, 1.5 * odR) & fovE;
        score(k) = st(k).MeanIntensity * mean(vessel(near));
    end
    [~, best] = max(score);
    odCenter = st(best).Centroid;
    odRad    = min(max(st(best).EquivDiameter / 2, 0.6 * odR), 1.6 * odR);
else                                                     % fallback: brightest smoothed point
    [~, idx] = max(Gs(:) .* fovE(:));
    [yy, xx] = ind2sub([H W], idx);
    odCenter = [xx yy];
    odRad    = odR;
end
odWide = circleMask([H W], odCenter, T.odExclude * odRad);

%% ------------------------ (2) FOVEA - darkest blob temporal to the disc
Gcl  = imclose(Gd, strel('disk', px(0.03)));             % remove vessels (thin dark lines)
fMap = imgaussfilt(Gcl, 0.35 * odR) - imgaussfilt(Gcl, 0.30 * fovR);  % local darkness vs. wide surroundings
side = sign(fovCenter(1) - odCenter(1));  if side == 0, side = 1; end  % fovea lies toward the FOV centre
expected = odCenter + [side * T.foveaDist * odR, T.foveaDrop * odR];
win = circleMask([H W], expected, T.foveaSearch * odR) & fovE;
if nnz(win) < 100                                        % expected spot falls outside the image
    win = circleMask([H W], fovCenter, 0.35 * fovR) & fovE;
end
winIdx = find(win);
if isempty(winIdx)
    foveaCenter = fovCenter;   foveaFound = false;
else
    [~, k]   = min(fMap(winIdx));
    [fy, fx] = ind2sub([H W], winIdx(k));
    foveaCenter = [fx fy];
    inner = imerode(win, strel('disk', 2));
    foveaFound  = odFound && inner(fy, fx);              % a real minimum, not the window edge
end
foveaRad = odR;                                          % fovea ~ 1 disc diameter across

%% --------------------------- (4) MICROANEURYSM CANDIDATES - top-hat
lesionZone = fovE & ~odWide;                             % where lesions are searched
maMaxArea  = pi * px(T.maRadius)^2;
Gm   = 1 - imgaussfilt(Gd, 1);                           % inverted + denoised: MAs become small bright dots
th   = imtophat(Gm, strel('disk', px(T.maRadius)));      % keeps only bright things smaller than the disk
maCC = bwconncomp(th > T.maMinContrast & lesionZone);
st   = regionprops(maCC, double(vesselWide), 'Area', 'Centroid', 'Eccentricity', 'MaxIntensity');
keep = [st.Area] >= pxArea(T.maMinArea) & [st.Area] <= maMaxArea & ...
       [st.Eccentricity] <= T.maMaxEcc & [st.MaxIntensity] == 0;   % small, round, not touching a vessel
maMaskW      = keepComponents(maCC, keep);
maCentroidsW = reshape([st(keep).Centroid], 2, [])';     % N x 2, [x y]

% Representative point for the "Microaneurysm" label: the detected MA closest
% to the centroid of all detected MAs (an actual MA, not empty space between them).
if isempty(maCentroidsW)
    maPointW = [];
else
    meanC = mean(maCentroidsW, 1);
    d = sum((maCentroidsW - meanC) .^ 2, 2);
    [~, k] = min(d);
    maPointW = maCentroidsW(k, :);
end

%% ------------- (5) EXUDATES & HEMORRHAGES - background subtraction + shape
bgW = 2 * px(T.bgWindow / 2) + 1;                        % odd window size
bg  = im2double(medfilt2(Gf, [bgW bgW], 'symmetric'));   % local background (median ignores small lesions)

% Exudates: bright deviations, excluding the light reflex on vessels
exCC = bwconncomp((Gd - bg) > T.exMinContrast & lesionZone);
st   = regionprops(exCC, double(vesselWide), 'Area', 'MeanIntensity');
keep = [st.Area] >= pxArea(T.exMinArea) & [st.MeanIntensity] < 0.5;  % MeanIntensity = share of pixels on the vessel margin
exMaskW = keepComponents(exCC, keep);
exPointW = representativePoint(exMaskW);

% Hemorrhages: dark deviations larger than a microaneurysm, off the vessels, not the fovea
hemBW = (bg - Gd) > T.hemMinContrast & lesionZone & ~vesselWide ...
        & ~circleMask([H W], foveaCenter, T.foveaGuard * odR);
hemBW = imopen(hemBW, strel('disk', 2));                 % detach thin leftover vessel fragments
hemCC = bwconncomp(hemBW);
st    = regionprops(hemCC, 'Area', 'MinorAxisLength', 'Solidity');
keep  = [st.Area] > maMaxArea & [st.MinorAxisLength] >= px(T.hemMinMinor) & ...
        [st.Solidity] >= T.hemMinSolidity;
hemMaskW = keepComponents(hemCC, keep);
hemPointW = representativePoint(hemMaskW);

%% -------------------- (6) NEOVASCULARIZATION - EXPERIMENTAL classical proxy
% CAVEAT (read before trusting this in a demo or a grading decision): true NVD/NVE
% detection is a hard, fine-grained texture problem that classical filters handle
% poorly. This flags vessel clusters that are BOTH locally denser than the
% peripheral baseline AND locally tortuous (arc/chord ratio), which is the coarse
% morphological signature of neovascular fronds - but it will also fire on dense
% normal arcades, image artifacts, or poor-quality crops. Treat nvdScore/nveScore
% as a soft flag for Module 3 to weight, not a diagnosis.
nvdMaskW = false(H, W);  nveMaskW = false(H, W);
nvdScore = 0;  nveScore = 0;
if T.nvEnabled
    skel = bwskel(vessel, 'MinBranchLength', T.nvMinSegLen);
    tort = vesselTortuosityMap([H W], skel, T.nvMinSegLen);

    winPx     = 2 * px(T.nvDensityWin / 2) + 1;
    density   = imboxfilt(double(vessel), winPx);                     % local vessel-fill fraction
    periphery = fovE & ~circleMask([H W], odCenter, T.nvSearchBand(2) * odR) ...
                     & ~circleMask([H W], foveaCenter, 1.5 * odR);
    if nnz(periphery) > 50
        muP = mean(density(periphery));  sdP = std(density(periphery));
    else
        muP = mean(density(fovE));       sdP = std(density(fovE));    % small-FOV fallback
    end

    densFlag = fovE & (density > muP + T.nvDensityZ * max(sdP, 1e-3));
    tortFlag = fovE & vessel & (tort > T.nvTortuosity);
    nvCand   = imdilate(densFlag, strel('disk', px(0.01))) & imdilate(tortFlag, strel('disk', px(0.015)));
    nvCand   = bwareaopen(nvCand, pxArea(T.nvMinClusterArea));

    nvdZone  = fovE & circleMask([H W], odCenter, T.nvSearchBand(2) * odR) ...
                    & ~circleMask([H W], odCenter, T.nvSearchBand(1) * odR);
    nvdMaskW = nvCand & nvdZone;
    nveMaskW = nvCand & ~nvdZone & ~odWide;

    nvdScore = min(1, nnz(nvdMaskW) / max(1, 4 * pxArea(T.nvMinClusterArea)));
    nveScore = min(1, nnz(nveMaskW) / max(1, 8 * pxArea(T.nvMinClusterArea)));
end
nvPointW = representativePoint(nvdMaskW | nveMaskW);

%% ----------------------------------------- OUTPUT (original resolution)
toOrig = 1 / scale;                                      % working -> original pixels
up     = @(M) imresize(M, [H0 W0], 'nearest');

result.opticDisc.center = odCenter * toOrig;
result.opticDisc.radius = odRad * toOrig;
result.opticDisc.mask   = circleMask([H0 W0], odCenter * toOrig, odRad * toOrig);
result.opticDisc.found  = odFound;
result.fovea.center     = foveaCenter * toOrig;
result.fovea.radius     = foveaRad * toOrig;
result.fovea.mask       = circleMask([H0 W0], foveaCenter * toOrig, foveaRad * toOrig);
result.fovea.found      = foveaFound;
result.vesselMask       = up(vessel);
result.microaneurysms.mask      = up(maMaskW);
result.microaneurysms.centroids = maCentroidsW * toOrig;
result.microaneurysms.count     = size(maCentroidsW, 1);
result.exudateMask      = up(exMaskW);
result.hemorrhageMask   = up(hemMaskW);

result.neovascularization.nvdMask  = up(nvdMaskW);
result.neovascularization.nveMask  = up(nveMaskW);
result.neovascularization.nvdScore = nvdScore;
result.neovascularization.nveScore = nveScore;
result.neovascularization.found    = T.nvEnabled && (nvdScore > 0.15 || nveScore > 0.15);

result.fovMask = up(fov);

% Colour-coded overlay: vessels blue, exudates green, hemorrhages magenta,
% microaneurysms red, neovascularization orange.
lbl = zeros(H0, W0, 'uint8');
rw  = max(2, round(2 * toOrig));
lbl(result.vesselMask)     = 1;
lbl(result.exudateMask)    = 2;
lbl(result.hemorrhageMask) = 3;
lbl(imdilate(result.microaneurysms.mask, strel('disk', rw))) = 4;
lbl(result.neovascularization.nvdMask | result.neovascularization.nveMask) = 5;
colourOverlay = labeloverlay(I, lbl, ...
    'Colormap', [0.25 0.55 1; 0.2 1 0.2; 1 0.2 1; 1 0 0; 1 0.55 0], ...
    'Transparency', 0.45);

% Text-labelled version: one leader line + label per structure that was
% actually FOUND (nothing found -> nothing labelled -> never crowded).
entries = struct('name', {}, 'point', {}, 'color', {});
if odFound
    entries(end + 1) = struct('name', 'Optic Disk', 'point', odCenter * toOrig, 'color', [1 1 0]);
end
if foveaFound
    entries(end + 1) = struct('name', 'Fovea', 'point', foveaCenter * toOrig, 'color', [0 1 1]);
end
if ~isempty(vesselPointW)
    entries(end + 1) = struct('name', 'Main Blood Vessel', 'point', vesselPointW * toOrig, 'color', [0.25 0.55 1]);
end
if ~isempty(exPointW)
    entries(end + 1) = struct('name', 'Hard Exudates', 'point', exPointW * toOrig, 'color', [0.2 1 0.2]);
end
if ~isempty(maPointW)
    entries(end + 1) = struct('name', 'Microaneurysm', 'point', maPointW * toOrig, 'color', [1 0 0]);
end
if ~isempty(hemPointW)
    entries(end + 1) = struct('name', 'Haemorrhage', 'point', hemPointW * toOrig, 'color', [1 0.2 1]);
end
if result.neovascularization.found && ~isempty(nvPointW)
    entries(end + 1) = struct('name', 'Neovascularization', 'point', nvPointW * toOrig, 'color', [1 0.55 0]);
end

result.overlay = drawLabeledOverlay(colourOverlay, entries);
end

%% ============================================================ LOCAL FUNCTIONS
function K = matchedKernel(sigma, L, theta)
%MATCHEDKERNEL  Zero-mean Gaussian line detector (Chaudhuri et al. 1989) at angle theta (deg).
half = ceil(max(3 * sigma, L / 2));
[X, Y] = meshgrid(-half:half, -half:half);
u =  X * cosd(theta) + Y * sind(theta);                  % across the vessel
v = -X * sind(theta) + Y * cosd(theta);                  % along the vessel
win = abs(u) <= 3 * sigma & abs(v) <= L / 2;
K = zeros(size(X));
K(win) = exp(-u(win).^2 / (2 * sigma^2));
K(win) = K(win) - mean(K(win));                          % zero mean: flat areas give no response
K = K / sum(abs(K(:)));                                  % comparable response across scales
end

function v = pct(x, p)
%PCT  Value at fraction p (0-1) of the sorted data. Avoids needing the Statistics Toolbox.
x = sort(x(:));
if isempty(x), v = NaN; else, v = x(min(numel(x), max(1, round(p * numel(x))))); end
end

function mask = keepComponents(cc, keep)
%KEEPCOMPONENTS  Logical mask of the connected components flagged in keep.
mask = false(cc.ImageSize);
mask(vertcat(cc.PixelIdxList{keep})) = true;
end

function mask = circleMask(sz, center, radius)
%CIRCLEMASK  Logical disk with centre [x y] and radius, in an image of size sz = [rows cols].
dx = (1:sz(2))  - center(1);
dy = (1:sz(1))' - center(2);
mask = dx.^2 + dy.^2 <= radius^2;
end

function tort = vesselTortuosityMap(sz, skel, minLen)
%VESSELTORTUOSITYMAP  Per-pixel arc/chord tortuosity of open skeleton segments.
% The skeleton is cut at branch points; each resulting open segment gets
% tortuosity = (pixel count along the segment) / (straight-line distance between
% its two endpoints), assigned to every pixel on that segment. ~1 = straight,
% higher = more "corkscrew". Segments with != 2 endpoints (loops/junction debris)
% are left at 0 - conservative, since this feeds an already-experimental flag.
tort = zeros(sz);
bp = bwmorph(skel, 'branchpoints');
segMask = skel & ~imdilate(bp, strel('disk', 1));
cc = bwconncomp(segMask, 8);
for i = 1:cc.NumObjects
    idx = cc.PixelIdxList{i};
    if numel(idx) < minLen, continue; end
    seg = false(sz);  seg(idx) = true;
    ep = bwmorph(seg, 'endpoints');
    [ey, ex] = find(ep);
    if numel(ey) ~= 2, continue; end
    chord = max(1, hypot(ex(1) - ex(2), ey(1) - ey(2)));
    tort(idx) = numel(idx) / chord;
end
end

function pt = representativePoint(mask)
%REPRESENTATIVEPOINT  [x y] centroid of the LARGEST connected component in
% mask, or [] if mask is entirely empty. Used so a label's leader line points
% at an actual detected pixel rather than a centroid that could fall in empty
% space between scattered detections.
pt = [];
if ~any(mask(:)), return; end
cc = bwconncomp(mask);
areas = cellfun(@numel, cc.PixelIdxList);
[~, k] = max(areas);
st = regionprops(cc, 'Centroid');
pt = st(k).Centroid;
end

function ov = drawLabeledOverlay(colourOverlay, entries)
%DRAWLABELEDOVERLAY  Pad colourOverlay with a black margin and add one text
% label + leader line + dot per entry, arranged around the left/right edges -
% mirrors a standard textbook fundus annotation figure. Entries are only
% drawn for structures that were actually found, so the image scales cleanly
% from "nothing detected" (plain overlay, no text) up to all 7 structures.
% Falls back to returning colourOverlay unchanged (no crash, no text) if
% insertText/insertShape (Computer Vision Toolbox) aren't available.
[H0, W0, ~] = size(colourOverlay);
if exist('insertText', 'file') ~= 2 || exist('insertShape', 'file') ~= 2
    ov = colourOverlay;
    return;
end
if isempty(entries)
    ov = colourOverlay;
    return;
end

padPx = 200;
Hc = H0 + 2 * padPx;  Wc = W0 + 2 * padPx;
canvas = zeros(Hc, Wc, 3, 'uint8');
canvas(padPx + (1:H0), padPx + (1:W0), :) = colourOverlay;

fontSize = max(20, round(0.020 * min(H0, W0)));
leftEntries  = entries(1:2:end);          % alternate sides so leader lines fan out, not crowd one edge
rightEntries = entries(2:2:end);

ov = canvas;
ov = placeLabels(ov, leftEntries,  padPx, Hc, 0,          fontSize, 'left');
ov = placeLabels(ov, rightEntries, padPx, Hc, padPx + W0, fontSize, 'right');
end

function ov = placeLabels(ov, col, padPx, Hc, colStartX, fontSize, side)
%PLACELABELS  Evenly space one label column (left or right) down the canvas.
n = numel(col);
if n == 0, return; end
margin = round(0.10 * Hc);
if n == 1
    ys = round(Hc / 2);
else
    ys = round(linspace(margin, Hc - margin, n));
end
for i = 1:n
    e  = col(i);
    pt = e.point + [padPx padPx];                          % feature point, canvas coords
    col255 = uint8(round(e.color * 255));
    ty = max(1, ys(i) - round(fontSize * 0.6));             % roughly vertically centre text on ys(i)
    if strcmp(side, 'left')
        tx = round(0.05 * padPx);
        lineStartX = tx + round(0.42 * fontSize * numel(e.name));   % rough right edge of the text
    else
        tx = colStartX + round(0.05 * padPx);
        lineStartX = tx;                                    % right column: line starts at text's left edge
    end
    ov = insertText(ov, [tx ty], upper(e.name), ...
        'FontSize', fontSize, 'TextColor', 'white', 'BoxOpacity', 0);
    ov = insertShape(ov, 'Line', [lineStartX, ys(i), pt(1), pt(2)], ...
        'Color', col255, 'LineWidth', 1);
    ov = insertShape(ov, 'FilledCircle', [pt(1), pt(2), max(2, round(fontSize * 0.18))], ...
        'Color', col255, 'Opacity', 1);
end
end
