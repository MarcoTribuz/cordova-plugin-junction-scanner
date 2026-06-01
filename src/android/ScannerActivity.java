package com.marcotribuzio.junction.scanner;

import android.annotation.SuppressLint;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.TextView;

import androidx.activity.ComponentActivity;
import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.ExperimentalGetImage;
import androidx.camera.core.ImageAnalysis;
import androidx.camera.core.ImageProxy;
import androidx.camera.core.Preview;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.view.PreviewView;
import androidx.core.content.ContextCompat;

import com.google.common.util.concurrent.ListenableFuture;
import com.google.mlkit.vision.barcode.BarcodeScanner;
import com.google.mlkit.vision.barcode.BarcodeScannerOptions;
import com.google.mlkit.vision.barcode.BarcodeScanning;
import com.google.mlkit.vision.barcode.common.Barcode;
import com.google.mlkit.vision.common.InputImage;

import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Full-screen branded scanner: CameraX live preview + ML Kit barcode analyzer +
 * {@link ScannerOverlayView} (dimmed mask, reticle, animated scan-line).
 *
 * Returns the first detected barcode via setResult(RESULT_OK, { text, format }).
 * Close button / back press → RESULT_CANCELED.
 */
public class ScannerActivity extends ComponentActivity {

    public static final String EXTRA_FORMATS = "formats";
    public static final String EXTRA_TORCH   = "torch";
    public static final String EXTRA_FRONT   = "front";
    public static final String EXTRA_PROMPT  = "prompt";
    public static final String RESULT_TEXT   = "text";
    public static final String RESULT_FORMAT = "format";

    private ExecutorService analysisExecutor;
    private BarcodeScanner barcodeScanner;
    private androidx.camera.core.Camera camera;
    private boolean delivered = false;
    private boolean torchOn = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        String formatsCsv = getIntent().getStringExtra(EXTRA_FORMATS);
        torchOn           = getIntent().getBooleanExtra(EXTRA_TORCH, false);
        final boolean front = getIntent().getBooleanExtra(EXTRA_FRONT, false);
        String prompt       = getIntent().getStringExtra(EXTRA_PROMPT);

        analysisExecutor = Executors.newSingleThreadExecutor();
        barcodeScanner   = BarcodeScanning.getClient(buildOptions(formatsCsv));

        // ── View tree (built programmatically; no plugin res files) ──────
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        final PreviewView previewView = new PreviewView(this);
        previewView.setLayoutParams(new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        root.addView(previewView);

        ScannerOverlayView overlay = new ScannerOverlayView(this);
        overlay.setLayoutParams(new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        root.addView(overlay);

        // Prompt under the reticle.
        if (prompt != null && !prompt.isEmpty()) {
            TextView hint = new TextView(this);
            hint.setText(prompt);
            hint.setTextColor(Color.WHITE);
            hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
            hint.setGravity(Gravity.CENTER);
            FrameLayout.LayoutParams hp = new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            hp.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
            hp.bottomMargin = dp(120);
            hint.setLayoutParams(hp);
            root.addView(hint);
        }

        // Close button.
        Button close = new Button(this);
        close.setText("✕"); // ✕
        close.setTextColor(Color.WHITE);
        close.setBackgroundColor(Color.TRANSPARENT);
        close.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        FrameLayout.LayoutParams cp = new FrameLayout.LayoutParams(dp(56), dp(56));
        cp.gravity = Gravity.TOP | Gravity.START;
        cp.topMargin = dp(24);
        cp.leftMargin = dp(8);
        close.setLayoutParams(cp);
        close.setOnClickListener(v -> cancelAndFinish());
        root.addView(close);

        // Torch toggle.
        final Button torch = new Button(this);
        torch.setText("⚡"); // ⚡
        torch.setTextColor(Color.WHITE);
        torch.setBackgroundColor(Color.TRANSPARENT);
        torch.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        FrameLayout.LayoutParams tp = new FrameLayout.LayoutParams(dp(56), dp(56));
        tp.gravity = Gravity.TOP | Gravity.END;
        tp.topMargin = dp(24);
        tp.rightMargin = dp(8);
        torch.setLayoutParams(tp);
        torch.setOnClickListener(v -> toggleTorch());
        root.addView(torch);

        setContentView(root);

        startCamera(previewView, front);
    }

    private BarcodeScannerOptions buildOptions(String csv) {
        if (csv != null && !csv.isEmpty()) {
            String[] tokens = csv.split(",");
            int acc = 0;
            for (String t : tokens) acc |= formatToken(t.trim());
            if (acc != 0) {
                return new BarcodeScannerOptions.Builder().setBarcodeFormats(acc).build();
            }
        }
        // Fallback: all formats.
        return new BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_ALL_FORMATS).build();
    }

    private int formatToken(String t) {
        switch (t.toUpperCase()) {
            case "QR_CODE":     return Barcode.FORMAT_QR_CODE;
            case "DATA_MATRIX": return Barcode.FORMAT_DATA_MATRIX;
            case "EAN_13":      return Barcode.FORMAT_EAN_13;
            case "EAN_8":       return Barcode.FORMAT_EAN_8;
            case "CODE_128":    return Barcode.FORMAT_CODE_128;
            case "CODE_39":     return Barcode.FORMAT_CODE_39;
            case "CODE_93":     return Barcode.FORMAT_CODE_93;
            case "ITF":         return Barcode.FORMAT_ITF;
            case "UPC_A":       return Barcode.FORMAT_UPC_A;
            case "UPC_E":       return Barcode.FORMAT_UPC_E;
            case "PDF_417":     return Barcode.FORMAT_PDF417;
            case "AZTEC":       return Barcode.FORMAT_AZTEC;
            case "CODABAR":     return Barcode.FORMAT_CODABAR;
            default:            return 0;
        }
    }

    private void startCamera(final PreviewView previewView, final boolean front) {
        final ListenableFuture<ProcessCameraProvider> future = ProcessCameraProvider.getInstance(this);
        future.addListener(() -> {
            try {
                ProcessCameraProvider provider = future.get();

                Preview preview = new Preview.Builder().build();
                preview.setSurfaceProvider(previewView.getSurfaceProvider());

                ImageAnalysis analysis = new ImageAnalysis.Builder()
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build();
                analysis.setAnalyzer(analysisExecutor, this::analyze);

                CameraSelector selector = front
                        ? CameraSelector.DEFAULT_FRONT_CAMERA
                        : CameraSelector.DEFAULT_BACK_CAMERA;

                provider.unbindAll();
                camera = provider.bindToLifecycle(this, selector, preview, analysis);

                if (torchOn && camera.getCameraInfo().hasFlashUnit()) {
                    camera.getCameraControl().enableTorch(true);
                }
            } catch (Exception e) {
                cancelAndFinish();
            }
        }, ContextCompat.getMainExecutor(this));
    }

    @OptIn(markerClass = ExperimentalGetImage.class)
    @SuppressLint("UnsafeOptInUsageError")
    private void analyze(@NonNull ImageProxy imageProxy) {
        if (delivered || imageProxy.getImage() == null) {
            imageProxy.close();
            return;
        }
        InputImage image = InputImage.fromMediaImage(
                imageProxy.getImage(), imageProxy.getImageInfo().getRotationDegrees());
        barcodeScanner.process(image)
                .addOnSuccessListener(this::onBarcodes)
                .addOnCompleteListener(t -> imageProxy.close());
    }

    private void onBarcodes(List<Barcode> barcodes) {
        if (delivered || barcodes == null || barcodes.isEmpty()) return;
        for (Barcode b : barcodes) {
            String value = b.getRawValue();
            if (value != null && !value.isEmpty()) {
                deliver(value, formatName(b.getFormat()));
                return;
            }
        }
    }

    private String formatName(int format) {
        switch (format) {
            case Barcode.FORMAT_QR_CODE:     return "QR_CODE";
            case Barcode.FORMAT_DATA_MATRIX: return "DATA_MATRIX";
            case Barcode.FORMAT_EAN_13:      return "EAN_13";
            case Barcode.FORMAT_EAN_8:       return "EAN_8";
            case Barcode.FORMAT_CODE_128:    return "CODE_128";
            case Barcode.FORMAT_CODE_39:     return "CODE_39";
            case Barcode.FORMAT_CODE_93:     return "CODE_93";
            case Barcode.FORMAT_ITF:         return "ITF";
            case Barcode.FORMAT_UPC_A:       return "UPC_A";
            case Barcode.FORMAT_UPC_E:       return "UPC_E";
            case Barcode.FORMAT_PDF417:      return "PDF_417";
            case Barcode.FORMAT_AZTEC:       return "AZTEC";
            case Barcode.FORMAT_CODABAR:     return "CODABAR";
            default:                         return "UNKNOWN";
        }
    }

    private void deliver(final String text, final String format) {
        if (delivered) return;
        delivered = true;
        runOnUiThread(() -> {
            Intent data = new Intent();
            data.putExtra(RESULT_TEXT, text);
            data.putExtra(RESULT_FORMAT, format);
            setResult(RESULT_OK, data);
            finish();
        });
    }

    private void toggleTorch() {
        if (camera == null || !camera.getCameraInfo().hasFlashUnit()) return;
        torchOn = !torchOn;
        camera.getCameraControl().enableTorch(torchOn);
    }

    private void cancelAndFinish() {
        setResult(RESULT_CANCELED);
        finish();
    }

    @Override
    public void onBackPressed() {
        cancelAndFinish();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (analysisExecutor != null) analysisExecutor.shutdown();
        if (barcodeScanner != null) barcodeScanner.close();
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
