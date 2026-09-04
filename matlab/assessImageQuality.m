function result = assessImageQuality(imagePath)
%ASSESSIMAGEQUALITY  Quality assessment for retinal (fundus) images.
%
%   result = assessImageQuality(imagePath)
%
%   Pipeline:  (1) load -> (4) field of view via Hough circle -> (2) blur via
%   Laplacian variance -> (3) exposure via histogram -> decide -> (5) enhance
%   borderline images with CLAHE (adapthisteq) + edge-preserving denoising.
%
%   result.status          'pass' | 'enhanced' | 'reject'
%   result.reason          why the image got that status
%   result.processedImage  original (pass), enhanced copy (enhanced), [] (reject)
%   result.metrics         every measured value - use these to tune T below
%
%   Requires the Image Processing Toolbox.
%
%   Example:
%       r = assessImageQuality('fundus01.jpg');
%       disp(r.status), disp(r.reason), disp(r.metrics)
%       if ~strcmp(r.status, 'reject'), imshow(r.processedImage), end

%% ------------------------------------------------------------------ SETTINGS
% Thresholds are STARTING POINTS. Run a few known good/bad images, inspect
% result.metrics, and adjust. Metrics are computed on a copy whose long side
% is T.workLongSide px, so values are comparable across image sizes.
T.workLongSide     = 1024;          % copy used for metrics (never upsampled)
T.houghLongSide    = 320;           % small copy used for circle detection
T.houghRadiusRel   = [0.25 0.55];   % FOV radius as a fraction of the long side
T.houghSensitivity = 0.92;          % imfindcircles sensitivity (0-1)
T.houghMinIoU      = 0.60;          % circle must overlap the intensity mask this much
T.backgroundLevel  = 15;            % luminance <= this: background / near-black
T.saturationLevel  = 250;           % luminance >= this: saturated

T.fovMinFill       = 0.30;   % reject if retina covers < 30% of the frame
T.fovMinVisible    = 0.55;   % reject if < 55% of the FOV circle is inside the frame

T.blurReject       = 15;     % Laplacian variance of the green channel (0-255 scale)
T.blurBorderline   = 40;

T.meanMinReject    = 20;     % mean luminance inside the FOV (0-255)
T.meanMinBorder    = 45;
T.meanMaxBorder    = 170;
T.meanMaxReject    = 215;
T.darkBorder       = 0.15;   % fraction of FOV pixels that are near-black
T.darkReject       = 0.40;
T.satBorder        = 0.02;   % fraction of FOV pixels that are saturated
T.satReject        = 0.10;
T.contrastBorder   = 60;     % 2.5th-97.5th percentile luminance spread

T.claheClipLimit   = 0.01;   % adapthisteq settings used for enhancement
T.claheNumTiles    = [8 8];

%% ------------------------------------------------------------------ (1) LOAD
if exist('imfindcircles', 'file') ~= 2
    error('assessImageQuality:noToolbox', 'The Image Processing Toolbox is required.');
end
imagePath = char(imagePath);
if ~isfile(imagePath)
    error('assessImageQuality:fileNotFound', 'File not found: %s', imagePath);
end
[I, cmap] = imread(imagePath);
if ~isempty(cmap),  I = ind2rgb(I, cmap);  end     % indexed image -> RGB
if size(I, 3) > 3,  I = I(:, :, 1:3);      end     % drop alpha / extra channels
I = im2uint8(I);                                   % uint16 / double -> uint8
isRGB = (size(I, 3) == 3);
[H, W, ~] = size(I);

% Downsized copies: Iw for metrics, Is for circle detection
Iw = imresize(I, min(1, T.workLongSide  / max(H, W)));
Is = imresize(I, min(1, T.houghLongSide / max(H, W)));
if isRGB
    Yw = rgb2gray(Iw);   Ys = rgb2gray(Is);   Gw = Iw(:, :, 2);   % luminance, green
else
    Yw = Iw;             Ys = Is;             Gw = Iw;
end

%% ------------------------------------ (4) FIELD OF VIEW - Hough circle detection
rRange = round(T.houghRadiusRel * max(size(Ys)));
[centers, radii] = imfindcircles(Ys, rRange, ...
    'ObjectPolarity', 'bright', 'Sensitivity', T.houghSensitivity);

% Plain intensity mask: sanity check for the circle, and fallback if none is found
threshMask = bwareafilt(imfill(Ys > T.backgroundLevel, 'holes'), 1);

houghOK = ~isempty(centers);
if houghOK
    circMask = circleMask(size(Ys), centers(1, :), radii(1));     % strongest circle
    iou = nnz(circMask & threshMask) / nnz(circMask | threshMask);
    houghOK = iou >= T.houghMinIoU;
end

if houghOK
    sF = H / size(Ys, 1);                    % small -> full-res scale
    sW = size(Yw, 1) / size(Ys, 1);          % small -> metric-copy scale
    fovCenter  = centers(1, :) * sF;         % [x y] in full-res pixels
    fovRadius  = radii(1) * sF;
    maskW      = circleMask(size(Yw), centers(1, :) * sW, radii(1) * sW);
    maskFull   = circleMask([H W], fovCenter, fovRadius);
    fovVisible = min(1, nnz(circMask) / (pi * radii(1)^2));   % part of the circle inside the frame
    fovMethod  = 'hough';
else
    maskW      = imresize(threshMask, size(Yw), 'nearest');
    maskFull   = imresize(threshMask, [H W],    'nearest');
    fovCenter  = [NaN NaN];   fovRadius = NaN;   fovVisible = NaN;   % NaN never triggers a reject
    fovMethod  = 'threshold-fallback';
end
fovFill = nnz(maskW) / numel(maskW);         % fraction of the frame that is retina

% Measure slightly inside the FOV edge: the edge itself is a huge artificial
% "edge" that would inflate the blur score and skew the histogram.
erodePx = max(3, round(0.03 * sqrt(nnz(maskW) / pi)));
maskE   = imerode(maskW, strel('disk', erodePx));

%% ------------------------------------------- (2) BLUR - Laplacian variance
lap = conv2(double(Gw), [0 1 0; 1 -4 1; 0 1 0], 'same');
m.laplacianVariance = var(lap(maskE));       % higher = sharper

%% ------------------------------------------ (3) EXPOSURE - histogram analysis
Yfov = double(Yw(maskE));
h = histcounts(Yfov, 0:256);                 % 256 bins; bin k holds luminance k-1
h = h / max(1, sum(h));                      % normalise to probabilities
c = cumsum(h);
m.meanLuminance     = sum((0:255) .* h);
m.darkFraction      = sum(h(1 : T.backgroundLevel + 1));
m.saturatedFraction = sum(h(T.saturationLevel + 1 : end));
if isempty(Yfov)
    m.meanLuminance = NaN;   m.luminanceRange95 = NaN;
else
    m.luminanceRange95 = find(c >= 0.975, 1) - find(c >= 0.025, 1);
end

m.fovFillRatio       = fovFill;
m.fovVisibleFraction = fovVisible;
m.fovCenter          = fovCenter;            % [x y], full-res pixels
m.fovRadius          = fovRadius;            % full-res pixels
m.fovMethod          = fovMethod;
m.luminanceHistogram = h;

%% ----------------------------------------------------------------- DECISION
rej = {};   bord = {};

if m.fovFillRatio < T.fovMinFill
    rej{end+1} = sprintf('retina covers only %.0f%% of the frame', 100 * m.fovFillRatio);
end
if m.fovVisibleFraction < T.fovMinVisible
    rej{end+1} = sprintf('field of view is cut off (%.0f%% visible)', 100 * m.fovVisibleFraction);
end

if m.laplacianVariance < T.blurReject
    rej{end+1}  = sprintf('too blurry (Laplacian variance %.1f)', m.laplacianVariance);
elseif m.laplacianVariance < T.blurBorderline
    bord{end+1} = sprintf('slightly blurry (Laplacian variance %.1f)', m.laplacianVariance);
end

if m.meanLuminance < T.meanMinReject || m.darkFraction > T.darkReject
    rej{end+1}  = sprintf('underexposed (mean luminance %.0f, %.0f%% near-black)', ...
                          m.meanLuminance, 100 * m.darkFraction);
elseif m.meanLuminance > T.meanMaxReject || m.saturatedFraction > T.satReject
    rej{end+1}  = sprintf('overexposed (mean luminance %.0f, %.0f%% saturated)', ...
                          m.meanLuminance, 100 * m.saturatedFraction);
elseif m.meanLuminance < T.meanMinBorder || m.darkFraction > T.darkBorder
    bord{end+1} = sprintf('slightly underexposed (mean luminance %.0f, %.0f%% near-black)', ...
                          m.meanLuminance, 100 * m.darkFraction);
elseif m.meanLuminance > T.meanMaxBorder || m.saturatedFraction > T.satBorder
    bord{end+1} = sprintf('slightly overexposed (mean luminance %.0f, %.0f%% saturated)', ...
                          m.meanLuminance, 100 * m.saturatedFraction);
end
if m.luminanceRange95 < T.contrastBorder
    bord{end+1} = sprintf('low contrast (luminance spread %.0f)', m.luminanceRange95);
end

%% ------------------------------------------------- (5) ENHANCE / (6) OUTPUT
if ~isempty(rej)
    status    = 'reject';
    reason    = ['Rejected: ' strjoin(rej, '; ')];
    processed = [];
elseif ~isempty(bord)
    status    = 'enhanced';
    reason    = ['Borderline, enhanced with CLAHE + denoising: ' strjoin(bord, '; ')];
    processed = enhanceImage(I, maskFull, T.claheClipLimit, T.claheNumTiles);
else
    status    = 'pass';
    reason    = sprintf('All checks passed (Laplacian variance %.1f, mean luminance %.0f, FOV fill %.0f%%)', ...
                        m.laplacianVariance, m.meanLuminance, 100 * m.fovFillRatio);
    processed = I;
end

result.status         = status;
result.reason         = reason;
result.processedImage = processed;
result.metrics        = m;
end

%% ============================================================ LOCAL FUNCTIONS
function mask = circleMask(sz, center, radius)
%CIRCLEMASK  Logical disk with centre [x y] and radius, in an image of size sz = [rows cols].
dx = (1:sz(2))  - center(1);               % 1 x cols
dy = (1:sz(1))' - center(2);               % rows x 1
mask = dx.^2 + dy.^2 <= radius^2;          % implicit expansion -> rows x cols
end

function J = enhanceImage(I, mask, clipLimit, numTiles)
%ENHANCEIMAGE  CLAHE on lightness (colours preserved) + edge-preserving denoising.
J = I;
% Fill the black background with the mean FOV colour so CLAHE tiles that
% straddle the FOV edge are not skewed by the black region.
for k = 1:size(J, 3)
    ch = J(:, :, k);
    ch(~mask) = mean(ch(mask));
    J(:, :, k) = ch;
end
if size(J, 3) == 3
    lab = rgb2lab(im2single(J));                         % L* in [0,100]
    lab(:, :, 1) = 100 * adapthisteq(lab(:, :, 1) / 100, ...
                         'ClipLimit', clipLimit, 'NumTiles', numTiles);
    J = lab2rgb(lab, 'OutputType', 'uint8');
else
    J = adapthisteq(J, 'ClipLimit', clipLimit, 'NumTiles', numTiles);
end
if exist('imbilatfilt', 'file') == 2
    J = imbilatfilt(J);                                  % edge-preserving denoise (R2018b+)
else
    J = imgaussfilt(J, 0.7);                             % fallback for older releases
end
J(repmat(~mask, [1 1 size(J, 3)])) = 0;                  % restore black background
end
