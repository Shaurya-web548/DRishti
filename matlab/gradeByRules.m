function [grade, details] = gradeByRules(lesionBundle, opticDiscCenter, opts)
%GRADEBYRULES  ICDR severity grade (0-4) from lesion findings, including the 4-2-1 rule.
%
%   [grade, details] = gradeByRules(lesionBundle, opticDiscCenter)
%
%   lesionBundle is a struct; every field is optional (missing = not found):
%     microaneurysms, hemorrhages, exudates, cottonWoolSpots   - lesion counts / locations
%     venousBeading, irma                                      - per-quadrant presence
%     neovascularization, vitreousHemorrhage                   - logical (PDR signs)
%   Each lesion field may be
%     an N x 2 list of [x y] pixel locations (binned into quadrants around the disc),
%     a 1 x 4 vector of counts / flags per quadrant
%        (order: upper-right, upper-left, lower-left, lower-right),
%     a scalar total (quadrant unknown, so it cannot satisfy the 4-quadrant rule),
%     a logical lesion mask, or a struct with .centroids / .countByQuadrant / .mask / .count.
%   The output struct of segmentRetina can be passed directly as lesionBundle.
%
%   opticDiscCenter = [x y] pixels. Quadrants are split by the horizontal and
%   vertical lines through it.
%
%   ICDR scale:
%     0  no DR              no lesions
%     1  mild NPDR          microaneurysms only
%     2  moderate NPDR      more than microaneurysms, but not severe
%     3  severe NPDR        4-2-1 rule: > 20 hemorrhages in EACH of 4 quadrants, OR
%                           venous beading in >= 2 quadrants, OR IRMA in >= 1 quadrant
%     4  PDR                neovascularisation or vitreous / pre-retinal hemorrhage
%   details.referable = grade >= 2 (moderate NPDR or worse).

arguments
    lesionBundle (1,1) struct
    opticDiscCenter (1,2) double = [NaN NaN]
    opts.HemorrhagesPerQuadrant (1,1) double = 20   % the "4" in 4-2-1: more than this in every quadrant
end
B   = lesionBundle;
odc = opticDiscCenter;

%% -------------------------------------------- per-quadrant counts / flags
MA   = quadrantCounts(pick(B, {'microaneurysms'}), odc);
HEM  = quadrantCounts(pick(B, {'hemorrhages', 'hemorrhageMask'}), odc);
EX   = quadrantCounts(pick(B, {'exudates', 'hardExudates', 'exudateMask'}), odc);
CWS  = quadrantCounts(pick(B, {'cottonWoolSpots', 'softExudates'}), odc);
VB   = quadrantCounts(pick(B, {'venousBeading'}), odc) > 0;
IRMA = quadrantCounts(pick(B, {'irma', 'IRMA'}), odc) > 0;
NV   = any(pick(B, {'neovascularization', 'neovascularisation'}), 'all');
VH   = any(pick(B, {'vitreousHemorrhage', 'preretinalHemorrhage'}), 'all');

found = {};
if any(HEM),  found{end+1} = sprintf('%d hemorrhage(s)', sum(HEM));                    end
if any(EX),   found{end+1} = sprintf('%d hard exudate(s)', sum(EX));                   end
if any(CWS),  found{end+1} = sprintf('%d cotton wool spot(s)', sum(CWS));              end
if any(VB),   found{end+1} = sprintf('venous beading in %d quadrant(s)', sum(VB));     end
if any(IRMA), found{end+1} = sprintf('IRMA in %d quadrant(s)', sum(IRMA));             end
if any(MA),   found{end+1} = sprintf('%d microaneurysm(s)', sum(MA));                  end

%% --------------------------------------------------------- ICDR decision
if NV || VH                                                      % --- PDR
    grade = 4;  crit = {};
    if NV, crit{end+1} = 'neovascularisation';                 end
    if VH, crit{end+1} = 'vitreous / pre-retinal hemorrhage';  end
else
    crit = {};                                                   % --- 4-2-1 rule
    if sum(HEM > opts.HemorrhagesPerQuadrant) == 4
        crit{end+1} = sprintf('>%d hemorrhages in all 4 quadrants', opts.HemorrhagesPerQuadrant);
    end
    if sum(VB) >= 2,   crit{end+1} = sprintf('venous beading in %d quadrants', sum(VB)); end
    if sum(IRMA) >= 1, crit{end+1} = sprintf('IRMA in %d quadrant(s)', sum(IRMA));      end
    if ~isempty(crit)
        grade = 3;                                               % severe NPDR
    elseif any(HEM) || any(EX) || any(CWS) || any(VB)
        grade = 2;  crit = found;                                % moderate NPDR
    elseif any(MA)
        grade = 1;  crit = found;                                % mild NPDR
    else
        grade = 0;  crit = {'no lesions'};
    end
end

labels = {'No DR', 'Mild NPDR', 'Moderate NPDR', 'Severe NPDR', 'PDR'};
details.grade         = grade;
details.label         = labels{grade + 1};
details.referable     = grade >= 2;
details.criteria      = crit;                                    % what triggered the grade
details.quadrantOrder = {'upper-right', 'upper-left', 'lower-left', 'lower-right'};
details.counts = struct('microaneurysms', MA, 'hemorrhages', HEM, 'hardExudates', EX, ...
                        'cottonWoolSpots', CWS, 'venousBeading', VB, 'irma', IRMA, ...
                        'neovascularization', NV, 'vitreousHemorrhage', VH);
end

%% ============================================================ LOCAL FUNCTIONS
function v = pick(s, names)
%PICK  First field of s whose name is in names, else [].
v = [];
for k = 1:numel(names)
    if isfield(s, names{k}), v = s.(names{k}); return; end
end
end

function q = quadrantCounts(item, odc)
%QUADRANTCOUNTS  1 x 4 lesion counts: upper-right, upper-left, lower-left, lower-right of the disc.
q = zeros(1, 4);
if isstruct(item)                                                % e.g. segmentRetina's microaneurysms struct
    if     isfield(item, 'countByQuadrant'), item = item.countByQuadrant;
    elseif isfield(item, 'centroids'),       item = item.centroids;
    elseif isfield(item, 'mask'),            item = item.mask;
    elseif isfield(item, 'count'),           item = item.count;
    else,  return;
    end
end
if isempty(item), return; end
if islogical(item) && ~isvector(item)                            % lesion mask -> one location per blob
    s = regionprops(item, 'Centroid');
    item = reshape([s.Centroid], 2, [])';
    if isempty(item), return; end
end
item = double(item);
if isscalar(item)
    q(1) = item;                                                 % total only: quadrant unknown
elseif isvector(item) && numel(item) == 4
    q = item(:)';                                                % already per quadrant
elseif size(item, 2) == 2                                        % N x 2 [x y] locations
    if any(isnan(odc))
        q(1) = size(item, 1);                                    % no disc centre: quadrant unknown
    else
        dx = item(:, 1) - odc(1);   dy = item(:, 2) - odc(2);    % image y axis points down
        quad = 1 * (dx >= 0 & dy <  0) + 2 * (dx <  0 & dy <  0) + ...
               3 * (dx <  0 & dy >= 0) + 4 * (dx >= 0 & dy >= 0);
        q = histcounts(quad, 0.5:1:4.5);
    end
else
    error('gradeByRules:badLesionField', ...
        'Lesion fields must be a scalar, a 1x4 vector, an Nx2 [x y] list, a mask, or a struct.');
end
end
