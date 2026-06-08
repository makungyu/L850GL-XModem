/* lpac-esim-download.js — v1.3.5 */
'use strict';

var uploadedFile = null;

/* ===== QR Image Handling ===== */

function handleQRFile(input) {
    if (!input.files || !input.files[0]) return;
    var file = input.files[0];
    uploadedFile = file;

    if (!file.type.match('image.*')) {
        alert('Please select an image file (JPG, PNG)');
        return;
    }

    var reader = new FileReader();
    reader.onload = function(e) {
        var preview = document.getElementById('qr-preview');
        preview.src = e.target.result;
        document.getElementById('qr-preview-container').style.display = 'block';
        hideDecodeStatus();
        setTimeout(decodeQRCode, 100);
    };
    reader.readAsDataURL(file);
}

function decodeQRCode() {
    if (!uploadedFile) return;

    hideDecodeStatus();
    document.getElementById('qr-decode-loading').style.display = 'block';

    if (typeof jsQR !== 'function') {
        document.getElementById('qr-decode-loading').style.display = 'none';
        showDecodeError('QR decoder library is not loaded. Please refresh the page and try again.');
        return;
    }

    var reader = new FileReader();
    reader.onload = function(e) {
        var img = new Image();
        img.onload = function() {
            var code = decodeImageWithJsQR(img);

            document.getElementById('qr-decode-loading').style.display = 'none';

            if (code && code.data) {
                if (validateLPA(code.data)) {
                    document.getElementById('lpa-activation-code').value = code.data;
                    document.getElementById('qr-decode-success').style.display = 'block';
                    setTimeout(function() {
                        document.getElementById('qr-decode-success').style.display = 'none';
                    }, 5000);
                } else {
                    showDecodeError('QR decoded but not a valid LPA code: ' + code.data.substring(0, 50));
                }
            } else {
                showDecodeError('No QR code found in image. Try a clearer photo.');
            }
        };
        img.onerror = function() {
            document.getElementById('qr-decode-loading').style.display = 'none';
            showDecodeError('Failed to load image.');
        };
        img.src = e.target.result;
    };
    reader.readAsDataURL(uploadedFile);
}

function decodeImageWithJsQR(img) {
    var attempts = [
        { maxSide: 1600, margin: 0, grayscale: false },
        { maxSide: 1200, margin: 0, grayscale: true },
        { maxSide: 900, margin: 24, grayscale: false },
        { maxSide: 700, margin: 48, grayscale: true }
    ];

    for (var i = 0; i < attempts.length; i++) {
        var imageData = renderQRImageData(img, attempts[i]);
        var code = jsQR(imageData.data, imageData.width, imageData.height, {
            inversionAttempts: 'attemptBoth'
        });

        if (code && code.data)
            return code;
    }

    return null;
}

function renderQRImageData(img, opts) {
    var scale = Math.min(1, opts.maxSide / Math.max(img.width, img.height));
    var width = Math.max(1, Math.round(img.width * scale));
    var height = Math.max(1, Math.round(img.height * scale));
    var margin = opts.margin || 0;
    var canvas = document.createElement('canvas');
    var ctx = canvas.getContext('2d');

    canvas.width = width + margin * 2;
    canvas.height = height + margin * 2;
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, margin, margin, width, height);

    var imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
    if (opts.grayscale)
        boostQRContrast(imageData.data);

    return imageData;
}

function boostQRContrast(data) {
    for (var i = 0; i < data.length; i += 4) {
        var gray = data[i] * 0.299 + data[i + 1] * 0.587 + data[i + 2] * 0.114;
        var value = gray > 140 ? 255 : 0;
        data[i] = value;
        data[i + 1] = value;
        data[i + 2] = value;
    }
}

function validateLPA(s) {
    if (typeof s !== 'string') return false;
    s = s.trim();
    // Light sanity: LPA:1$something$something — lpac does real parsing
    if (s.indexOf('LPA:1$') !== 0) return false;
    return s.indexOf('$', 6) > 6;
}

function clearQRUpload() {
    document.getElementById('qr-file').value = '';
    document.getElementById('qr-preview-container').style.display = 'none';
    uploadedFile = null;
    hideDecodeStatus();
}

function hideDecodeStatus() {
    var ids = ['qr-decode-loading', 'qr-decode-success', 'qr-decode-error'];
    ids.forEach(function(id) {
        var el = document.getElementById(id);
        if (el) el.style.display = 'none';
    });
}

function showDecodeError(msg) {
    var el = document.getElementById('qr-decode-error-message');
    if (el) el.textContent = msg;
    var errDiv = document.getElementById('qr-decode-error');
    if (errDiv) errDiv.style.display = 'block';
}

/* ===== Download Profile ===== */

function downloadProfile() {
    var lpa     = (document.getElementById('lpa-activation-code').value || '').trim();
    var smdp    = (document.getElementById('smdp-server').value || '').trim();
    var matchid = (document.getElementById('matching-id').value || '').trim();
    var confirm = (document.getElementById('confirmation-code').value || '').trim();

    if (!lpa && (!smdp || !matchid)) {
        alert('Enter an LPA activation code or SM-DP+ server with matching ID');
        return;
    }

    // Validate LPA format if provided
    if (lpa && !validateLPA(lpa)) {
        alert('Invalid LPA format. Expected: LPA:1$smdp.domain$matching-id');
        return;
    }

    hideDownloadStatus();
    document.getElementById('download-loading').style.display = 'block';

    var params = {};
    if (lpa) {
        params.lpa = lpa;
    } else {
        params.smdp = smdp;
        params.matching_id = matchid;
    }
    if (confirm) {
        params.confirmation = confirm;
    }

    apiPost('download', params)
        .then(function(data) {
            if (data && data.payload) {
                if (data.payload.message === 'processing') {
                    // Async — poll lock-status, check last_result
                    document.getElementById('download-loading').style.display = 'block';
                    startLockPolling(function(result) {
                        document.getElementById('download-loading').style.display = 'none';
                        if (result && result.success) {
                            showDownloadSuccess(result.message || 'Profile downloaded successfully!');
                        } else if (result && !result.success) {
                            showDownloadError(result.message || 'Download failed on backend');
                        } else {
                            showDownloadSuccess('Download completed. Refresh profiles to verify.');
                        }
                        if (typeof tabLoaded !== 'undefined') tabLoaded['profiles-tab'] = false;
                    });
                } else if (data.payload.code === 0) {
                    document.getElementById('download-loading').style.display = 'none';
                    showDownloadSuccess(data.payload.message || 'Profile downloaded successfully!');
                    if (typeof tabLoaded !== 'undefined') tabLoaded['profiles-tab'] = false;
                } else {
                    document.getElementById('download-loading').style.display = 'none';
                    var msg = data.payload.message || 'Download failed';
                    if (data.payload.data && data.payload.data.msg) msg += ': ' + data.payload.data.msg;
                    showDownloadError(msg);
                }
            }
        })
        .catch(function(e) {
            document.getElementById('download-loading').style.display = 'none';
            showDownloadError(e.message || 'Network error during download');
        });
}

function clearDownloadForm() {
    document.getElementById('lpa-activation-code').value = '';
    document.getElementById('smdp-server').value = '';
    document.getElementById('matching-id').value = '';
    document.getElementById('confirmation-code').value = '';
    clearQRUpload();
    hideDownloadStatus();
}

function hideDownloadStatus() {
    var ids = ['download-loading', 'download-success', 'download-error'];
    ids.forEach(function(id) {
        var el = document.getElementById(id);
        if (el) el.style.display = 'none';
    });
}

function showDownloadSuccess(msg) {
    var el = document.getElementById('download-success-message');
    if (el) el.textContent = msg;
    var div = document.getElementById('download-success');
    if (div) div.style.display = 'block';
}

function showDownloadError(msg) {
    var el = document.getElementById('download-error-message');
    if (el) el.textContent = msg;
    var div = document.getElementById('download-error');
    if (div) div.style.display = 'block';
}
