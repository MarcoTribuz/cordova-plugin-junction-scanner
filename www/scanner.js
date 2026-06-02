var cordovaExec = require('cordova/exec');

/**
 * Launch the native branded barcode scanner.
 *
 * @param {Object}   [options]
 * @param {string}   [options.formats]            CSV of formats. Accepted tokens:
 *   QR_CODE, DATA_MATRIX, EAN_13, EAN_8, CODE_128, CODE_39, CODE_93,
 *   ITF, UPC_A, UPC_E, PDF_417, AZTEC, CODABAR.
 * @param {boolean}  [options.torchOn=false]      start with torch on.
 * @param {boolean}  [options.preferFrontCamera=false]
 * @param {string}   [options.prompt='']          hint text under the reticle.
 * @param {boolean}  [options.showScanLine=false]  show animated scan-line inside reticle.
 * @param {Function} success Callback receiving { text, format, cancelled }.
 *                           On user cancel: { text:'', format:'', cancelled:true }.
 * @param {Function} error   Callback receiving an error string (no camera / permission denied).
 */
exports.scan = function (options, success, error) {
  var o = options || {};
  cordovaExec(success, error, 'JunctionScanner', 'scan', [
    o.formats || 'QR_CODE,DATA_MATRIX,EAN_13,EAN_8,CODE_128,UPC_A,UPC_E,PDF_417,AZTEC',
    !!o.torchOn,
    !!o.preferFrontCamera,
    o.prompt || '',
    !!o.showScanLine
  ]);
};

/**
 * Resolves true if a usable camera is present on the device.
 * @param {Function} success Callback receiving a boolean.
 * @param {Function} error
 */
exports.isAvailable = function (success, error) {
  cordovaExec(success, error, 'JunctionScanner', 'isAvailable', []);
};
