const uploadDrop = document.getElementById('uploadDrop');
const imageInput = document.getElementById('imageInput');
const uploadLabel = document.getElementById('uploadLabel');
const scanForm = document.getElementById('scanForm');
const submitBtn = document.getElementById('submitBtn');
const loadingState = document.getElementById('loadingState');
const errorState = document.getElementById('errorState');
const resultState = document.getElementById('resultState');

let lastScanId = null;

// Scroll-to-scan buttons
document.getElementById('navStartBtn').onclick = () => scrollToScan();
document.getElementById('heroStartBtn').onclick = () => scrollToScan();
document.getElementById('howItWorksBtn').onclick = () => scrollToScan();
function scrollToScan() {
  document.getElementById('scan').scrollIntoView({ behavior: 'smooth' });
}

// File picker label + drag-and-drop
imageInput.addEventListener('change', () => {
  if (imageInput.files.length) {
    uploadLabel.textContent = imageInput.files[0].name;
  }
});
['dragover', 'dragenter'].forEach(evt =>
  uploadDrop.addEventListener(evt, e => {
    e.preventDefault();
    uploadDrop.classList.add('dragover');
  })
);
['dragleave', 'drop'].forEach(evt =>
  uploadDrop.addEventListener(evt, e => {
    e.preventDefault();
    uploadDrop.classList.remove('dragover');
  })
);
uploadDrop.addEventListener('drop', e => {
  const file = e.dataTransfer.files[0];
  if (file) {
    imageInput.files = e.dataTransfer.files;
    uploadLabel.textContent = file.name;
  }
});

scanForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  if (!imageInput.files.length) return;

  errorState.classList.add('hidden');
  resultState.classList.add('hidden');
  loadingState.classList.remove('hidden');
  submitBtn.disabled = true;

  const formData = new FormData();
  formData.append('image', imageInput.files[0]);

  try {
    const res = await fetch('/api/scan', { method: 'POST', body: formData });
    const data = await res.json();

    if (!res.ok || data.error) {
      throw new Error(data.error || 'Something went wrong analyzing this image.');
    }
    if (data.mode === 'rejected') {
      throw new Error(data.message || 'Image quality too low to grade. Please retake the photo.');
    }

    renderResult(data);
  } catch (err) {
    errorState.textContent = err.message;
    errorState.classList.remove('hidden');
  } finally {
    loadingState.classList.add('hidden');
    submitBtn.disabled = false;
  }
});

function renderResult(data) {
  lastScanId = data.scan_id;

  const modeBadge = document.getElementById('modeBadge');
  if (data.mode === 'real_full') {
    modeBadge.textContent = 'AI-ASSISTED (CNN + RULES)';
    modeBadge.classList.remove('rule-based');
  } else {
    modeBadge.textContent = 'RULE-BASED GRADING';
    modeBadge.classList.add('rule-based');
  }

  document.getElementById('gradeHeadline').textContent =
    `Grade ${data.grade} - ${data.grade_label}${data.referable ? ' (Referable)' : ''}`;

  document.getElementById('confidenceLine').textContent =
    typeof data.confidence === 'number'
      ? `AI confidence: ${Math.round(data.confidence * 100)}%`
      : 'Confidence score not available in rule-based mode.';

  document.getElementById('imgOriginal').src = data.original_url;

  const figOverlay = document.getElementById('figOverlay');
  const figGradcam = document.getElementById('figGradcam');
  if (data.overlay_url) {
    document.getElementById('imgOverlay').src = data.overlay_url;
    figOverlay.classList.remove('hidden');
  } else {
    figOverlay.classList.add('hidden');
  }
  if (data.gradcam_url) {
    document.getElementById('imgGradcam').src = data.gradcam_url;
    figGradcam.classList.remove('hidden');
  } else {
    figGradcam.classList.add('hidden');
  }

  resultState.classList.remove('hidden');
}

document.getElementById('downloadReportBtn').addEventListener('click', () => {
  if (!lastScanId) return;
  const name = encodeURIComponent(document.getElementById('patientName').value || '-');
  const age = encodeURIComponent(document.getElementById('patientAge').value || '-');
  const location = encodeURIComponent(document.getElementById('patientLocation').value || '-');
  window.location.href = `/api/report/${lastScanId}?name=${name}&age=${age}&location=${location}`;
});
