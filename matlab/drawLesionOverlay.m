function overlay = drawLesionOverlay(image, lesionBundle, opts)
%DRAWLESIONOVERLAY  Draw lesion markers and outlines onto a retinal image.
%
%   overlay = drawLesionOverlay(image, lesionBundle)
%   overlay = drawLesionOverlay(image, lesionBundle, LineWidth=3, MarkerRadius=10)
%
%   image         file path, or RGB / grayscale array
%   lesionBundle  struct; every field is optional:
%     microaneurysms   N x 2 [x y] pixel coordinates          -> red rings
%     exudateMask      logical mask                            -> green outlines
%     hemorrhageMask   logical mask                            -> magenta outlines
%     opticDisc, fovea structs with .center [x y], .radius     -> yellow / cyan circles
%   Any lesion field may also be an N x 2 list (drawn as rings), a mask (drawn
%   as outlines) or a struct with .centroids / .mask. The output struct of
%   segmentRetina can be passed directly. Masks of a different size than the
%   image are resized to fit.
%
%   overlay is a uint8 RGB image the same size as the input.
%   Needs the Image Processing Toolbox.

arguments
    image
    lesionBundle (1,1) struct = struct()
    opts.LineWidth (1,1) double = NaN      % px; default 0.3 % of image width, at least 2
    opts.MarkerRadius (1,1) double = NaN   % px; default 1 % of image width, at least 6
end
img = loadImage(image);
W  = size(img, 2);
lw = opts.LineWidth;     if isnan(lw), lw = max(2, round(0.003 * W)); end
mr = opts.MarkerRadius;  if isnan(mr), mr = max(6, round(0.010 * W)); end

overlay = img;
overlay = drawItem(overlay, pick(lesionBundle, {'exudateMask', 'exudates', 'hardExudates'}),   [0.2 1 0.2], lw, mr);
overlay = drawItem(overlay, pick(lesionBundle, {'hemorrhageMask', 'hemorrhages'}),            [1 0.2 1],   lw, mr);
overlay = drawItem(overlay, pick(lesionBundle, {'microaneurysms', 'microaneurysmCentroids'}), [1 0 0],     lw, mr);
overlay = drawItem(overlay, pick(lesionBundle, {'opticDisc'}),                                [1 1 0],     lw, mr);
overlay = drawItem(overlay, pick(lesionBundle, {'fovea'}),                                    [0 1 1],     lw, mr);
end

%% ============================================================ LOCAL FUNCTIONS
function img = drawItem(img, item, color, lw, r)
%DRAWITEM  Circle a {center, radius} struct, ring a list of points, or outline a mask.
sz = [size(img, 1) size(img, 2)];
if isstruct(item)
    if isfield(item, 'center') && isfield(item, 'radius')                        % disc / fovea
        img = imoverlay(img, ringMask(sz, item.center, item.radius, lw), color);
        return
    elseif isfield(item, 'centroids')
        item = item.centroids;
    elseif isfield(item, 'mask')
        item = item.mask;
    else
        return
    end
end
if isempty(item), return; end
if (islogical(item) && ~isvector(item)) || (isnumeric(item) && size(item, 2) ~= 2)   % mask
    mask = logical(item);
    if ~isequal(size(mask), sz), mask = imresize(mask, sz, 'nearest'); end
    outline = imdilate(bwperim(mask), strel('disk', max(1, floor(lw / 2))));
    img = imoverlay(img, outline, color);
else                                                                                  % N x 2 [x y]
    img = imoverlay(img, ringMask(sz, double(item), r, lw), color);
end
end

function m = ringMask(sz, centers, radius, lw)
%RINGMASK  Logical mask with a ring of width lw and the given radius around each [x y] centre.
m = false(sz);
radius = radius(:) .* ones(size(centers, 1), 1);
for k = 1:size(centers, 1)
    cx = centers(k, 1);  cy = centers(k, 2);  rad = radius(k);
    if ~all(isfinite([cx cy rad])), continue; end
    x = max(1, floor(cx - rad - lw)) : min(sz(2), ceil(cx + rad + lw));
    y = max(1, floor(cy - rad - lw)) : min(sz(1), ceil(cy + rad + lw));
    if isempty(x) || isempty(y), continue; end
    [X, Y] = meshgrid(x, y);
    d2 = (X - cx).^2 + (Y - cy).^2;
    m(y, x) = m(y, x) | (d2 <= (rad + lw / 2)^2 & d2 >= max(0, rad - lw / 2)^2);
end
end

function v = pick(s, names)
%PICK  First field of s whose name is in names, else [].
v = [];
for k = 1:numel(names)
    if isfield(s, names{k}), v = s.(names{k}); return; end
end
end

function img = loadImage(image)
if ischar(image) || isstring(image), img = imread(char(image)); else, img = image; end
if size(img, 3) > 3, img = img(:, :, 1:3); end
img = im2uint8(img);
if size(img, 3) == 1, img = repmat(img, [1 1 3]); end
end
