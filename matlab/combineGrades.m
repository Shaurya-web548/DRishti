function out = combineGrades(cnnProbs, ruleGrade, referableThreshold, grades)
%COMBINEGRADES  Merge the CNN prediction with the rule-based ICDR grade for one image.
%
%   out = combineGrades(cnnProbs, ruleGrade, referableThreshold)
%   out = combineGrades(cnnProbs, ruleGrade, referableThreshold, grades)
%
%   cnnProbs            1 x 5 class probabilities from predictDRGrade
%   ruleGrade           0-4 from gradeByRules
%   referableThreshold  the CNN calls the image referable when P(grade >= 2) is at
%                       or above this - use tuneReferableThreshold (default 0.5)
%   grades              grade value of each probability column (default 0:4)
%
%   If the CNN grade equals the rule grade AND both agree on referable / not,
%   out.status = 'agree' and out.grade is that grade. Otherwise
%   out.status = 'review', out.grade = NaN, and out.referable is true if
%   EITHER method calls it referable (the safe default for screening).

if nargin < 3 || isempty(referableThreshold), referableThreshold = 0.5; end
if nargin < 4 || isempty(grades),             grades = 0:4;             end
cnnProbs = double(cnnProbs(:))';

[~, idx]      = max(cnnProbs);
cnnGrade      = grades(idx);
pReferable    = sum(cnnProbs(grades >= 2));
referableCNN  = pReferable >= referableThreshold;
referableRule = ruleGrade >= 2;

out.cnnGrade      = cnnGrade;
out.ruleGrade     = ruleGrade;
out.pReferable    = pReferable;
out.referableCNN  = referableCNN;
out.referableRule = referableRule;

if cnnGrade == ruleGrade && referableCNN == referableRule
    out.status    = 'agree';
    out.grade     = cnnGrade;
    out.referable = referableRule;
    out.reason    = sprintf('CNN and rules both give grade %d', cnnGrade);
else
    out.status    = 'review';
    out.grade     = NaN;
    out.referable = referableCNN || referableRule;
    out.reason    = sprintf('CNN grade %d (P(referable) = %.2f vs threshold %.2f) but rule grade %d', ...
                            cnnGrade, pReferable, referableThreshold, ruleGrade);
end
end
