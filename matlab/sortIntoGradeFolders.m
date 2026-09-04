function sortIntoGradeFolders(csvFile, imageDir, outDir, idColumn, gradeColumn)
%SORTINTOGRADEFOLDERS  Copy images into outDir/<grade>/ using a label CSV.
%
%   sortIntoGradeFolders(csvFile, imageDir, outDir, idColumn, gradeColumn)
%
%   Column names as used in each dataset's CSV:
%     APTOS 2019:  sortIntoGradeFolders('train.csv', 'train_images', 'data', 'id_code', 'diagnosis')
%     IDRiD:       sortIntoGradeFolders('IDRiD_Disease Grading_Training Labels.csv', ...
%                      'Training Set', 'data', 'Image name', 'Retinopathy grade')
%     Messidor-2:  sortIntoGradeFolders('messidor_data.csv', 'IMAGES', 'data', ...
%                      'image_id', 'adjudicated_dr_grade')
%
%   IDs may be given with or without the file extension. Rows with a missing
%   grade (e.g. ungradable images) are skipped. Run once per dataset - they all
%   merge into the same 0-4 folders, which is what trainDRClassifier reads.

tbl    = readtable(csvFile, 'VariableNamingRule', 'preserve', 'TextType', 'string');
ids    = string(tbl.(idColumn));
grades = tbl.(gradeColumn);
if ~isnumeric(grades), grades = str2double(string(grades)); end

nCopied = 0;  nMissing = 0;
for k = 1:numel(ids)
    if ismissing(ids(k)) || strlength(ids(k)) == 0 || isnan(grades(k)), continue; end
    src = fullfile(imageDir, ids(k));
    if ~isfile(src)                                              % id without extension -> find the file
        hit = dir(fullfile(imageDir, ids(k) + ".*"));
        if isempty(hit), nMissing = nMissing + 1; continue; end
        src = fullfile(hit(1).folder, hit(1).name);
    end
    dst = fullfile(outDir, num2str(grades(k)));
    if ~isfolder(dst), mkdir(dst); end
    copyfile(src, dst);
    nCopied = nCopied + 1;
end
fprintf('%s: copied %d images into %s (%d ids had no matching file)\n', csvFile, nCopied, outDir, nMissing);
end
