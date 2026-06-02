package com.marcotribuzio.junction.scanner;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Junction custom barcode scanner (Android bridge).
 *
 * Launches {@link ScannerActivity} (CameraX preview + ML Kit barcode analyzer +
 * branded overlay) and forwards its result to JS as { text, format, cancelled }.
 * Mirrors the docscanner plugin pattern (setActivityResultCallback + onActivityResult).
 */
public class JunctionScanner extends CordovaPlugin {

    private static final int REQ_SCAN   = 49310;
    private static final int REQ_CAMERA = 49311;

    private CallbackContext pendingCallback;

    // Captured scan args, held across the runtime-permission round-trip.
    private String  formats = "QR_CODE,DATA_MATRIX";
    private boolean torchOn = false;
    private boolean frontCamera = false;
    private String  prompt = "";
    private boolean showScanLine = false;

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) throws JSONException {
        if ("isAvailable".equals(action)) {
            boolean ok = cordova.getActivity().getPackageManager()
                    .hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY);
            callbackContext.sendPluginResult(new PluginResult(PluginResult.Status.OK, ok));
            return true;
        }
        if ("scan".equals(action)) {
            this.formats      = args.optString(0, "QR_CODE,DATA_MATRIX");
            this.torchOn      = args.optBoolean(1, false);
            this.frontCamera  = args.optBoolean(2, false);
            this.prompt       = args.optString(3, "");
            this.showScanLine = args.optBoolean(4, false);
            this.pendingCallback = callbackContext;

            if (!cordova.hasPermission(Manifest.permission.CAMERA)) {
                cordova.requestPermission(this, REQ_CAMERA, Manifest.permission.CAMERA);
            } else {
                launchScanner();
            }
            return true;
        }
        return false;
    }

    @Override
    public void onRequestPermissionResult(int requestCode, String[] permissions, int[] grantResults) {
        if (requestCode != REQ_CAMERA) return;
        if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            launchScanner();
        } else {
            fail("camera_permission_denied");
        }
    }

    private void launchScanner() {
        Activity activity = cordova.getActivity();
        Intent intent = new Intent(activity, ScannerActivity.class);
        intent.putExtra(ScannerActivity.EXTRA_FORMATS, formats);
        intent.putExtra(ScannerActivity.EXTRA_TORCH, torchOn);
        intent.putExtra(ScannerActivity.EXTRA_FRONT, frontCamera);
        intent.putExtra(ScannerActivity.EXTRA_PROMPT, prompt);
        intent.putExtra(ScannerActivity.EXTRA_SCAN_LINE, showScanLine);
        cordova.setActivityResultCallback(this);
        activity.startActivityForResult(intent, REQ_SCAN);
    }

    @Override
    public void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQ_SCAN) return;
        // Cancel (back button / close) → preserve the { cancelled:true } contract via OK.
        if (resultCode != Activity.RESULT_OK || data == null) {
            okResult("", "", true);
            return;
        }
        String text   = data.getStringExtra(ScannerActivity.RESULT_TEXT);
        String format = data.getStringExtra(ScannerActivity.RESULT_FORMAT);
        if (text == null) {
            okResult("", "", true);
            return;
        }
        okResult(text, format == null ? "" : format, false);
    }

    private void okResult(String text, String format, boolean cancelled) {
        if (pendingCallback == null) return;
        try {
            JSONObject out = new JSONObject();
            out.put("text", text);
            out.put("format", format);
            out.put("cancelled", cancelled);
            pendingCallback.sendPluginResult(new PluginResult(PluginResult.Status.OK, out));
        } catch (JSONException e) {
            pendingCallback.error("result_serialization_failed");
        }
        pendingCallback = null;
    }

    private void fail(String msg) {
        if (pendingCallback == null) return;
        pendingCallback.error(msg);
        pendingCallback = null;
    }
}
