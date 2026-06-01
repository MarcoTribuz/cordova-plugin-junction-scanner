package com.marcotribuzio.junction.scanner;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffXfermode;
import android.graphics.RectF;
import android.graphics.Shader;
import android.view.View;
import android.view.animation.LinearInterpolator;

/**
 * Branded scan overlay: a dimmed full-screen mask with a clear rounded reticle
 * in the center, corner brackets, and an animated scan-line sweeping vertically.
 *
 * Drawn entirely in code (no resources) so the plugin stays self-contained.
 */
public class ScannerOverlayView extends View {

    // Junction brand accent (teal/green). Adjust to match the app palette.
    private static final int ACCENT = Color.parseColor("#22D3A6");

    private final Paint maskPaint    = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint clearPaint   = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint cornerPaint  = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint linePaint    = new Paint(Paint.ANTI_ALIAS_FLAG);

    private final RectF reticle = new RectF();
    private float cornerRadius;
    private float scanY;
    private ValueAnimator scanAnimator;

    public ScannerOverlayView(Context context) {
        super(context);
        setLayerType(LAYER_TYPE_HARDWARE, null);

        maskPaint.setColor(Color.parseColor("#99000000")); // 60% black dim

        clearPaint.setColor(Color.TRANSPARENT);
        clearPaint.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.CLEAR));

        cornerPaint.setColor(ACCENT);
        cornerPaint.setStyle(Paint.Style.STROKE);
        cornerPaint.setStrokeWidth(dp(4));
        cornerPaint.setStrokeCap(Paint.Cap.ROUND);

        linePaint.setStyle(Paint.Style.FILL);

        cornerRadius = dp(20);
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        // Square reticle ~70% of the narrower dimension, vertically centered (slightly high).
        float side = Math.min(w, h) * 0.70f;
        float cx = w / 2f;
        float cy = h * 0.45f;
        reticle.set(cx - side / 2f, cy - side / 2f, cx + side / 2f, cy + side / 2f);
        startScanAnimation();
    }

    private void startScanAnimation() {
        if (scanAnimator != null) scanAnimator.cancel();
        scanAnimator = ValueAnimator.ofFloat(reticle.top + dp(8), reticle.bottom - dp(8));
        scanAnimator.setDuration(1800);
        scanAnimator.setRepeatMode(ValueAnimator.REVERSE);
        scanAnimator.setRepeatCount(ValueAnimator.INFINITE);
        scanAnimator.setInterpolator(new LinearInterpolator());
        scanAnimator.addUpdateListener(a -> {
            scanY = (float) a.getAnimatedValue();
            invalidate();
        });
        scanAnimator.start();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);

        // Dim everything, then punch the reticle hole.
        canvas.drawRect(0, 0, getWidth(), getHeight(), maskPaint);
        canvas.drawRoundRect(reticle, cornerRadius, cornerRadius, clearPaint);

        // Corner brackets.
        drawCorners(canvas);

        // Scan-line: a soft accent gradient band.
        float bandH = dp(3);
        LinearGradient grad = new LinearGradient(
                reticle.left, scanY - bandH, reticle.left, scanY + bandH,
                new int[]{0x0022D3A6, ACCENT, 0x0022D3A6},
                null, Shader.TileMode.CLAMP);
        linePaint.setShader(grad);
        canvas.drawRect(reticle.left + dp(6), scanY - bandH,
                reticle.right - dp(6), scanY + bandH, linePaint);
        linePaint.setShader(null);
    }

    private void drawCorners(Canvas canvas) {
        float len = dp(28);
        float r = cornerRadius;
        Path p = new Path();

        // Top-left
        p.moveTo(reticle.left, reticle.top + len);
        p.lineTo(reticle.left, reticle.top + r);
        p.quadTo(reticle.left, reticle.top, reticle.left + r, reticle.top);
        p.lineTo(reticle.left + len, reticle.top);
        // Top-right
        p.moveTo(reticle.right - len, reticle.top);
        p.lineTo(reticle.right - r, reticle.top);
        p.quadTo(reticle.right, reticle.top, reticle.right, reticle.top + r);
        p.lineTo(reticle.right, reticle.top + len);
        // Bottom-right
        p.moveTo(reticle.right, reticle.bottom - len);
        p.lineTo(reticle.right, reticle.bottom - r);
        p.quadTo(reticle.right, reticle.bottom, reticle.right - r, reticle.bottom);
        p.lineTo(reticle.right - len, reticle.bottom);
        // Bottom-left
        p.moveTo(reticle.left + len, reticle.bottom);
        p.lineTo(reticle.left + r, reticle.bottom);
        p.quadTo(reticle.left, reticle.bottom, reticle.left, reticle.bottom - r);
        p.lineTo(reticle.left, reticle.bottom - len);

        canvas.drawPath(p, cornerPaint);
    }

    @Override
    protected void onDetachedFromWindow() {
        super.onDetachedFromWindow();
        if (scanAnimator != null) scanAnimator.cancel();
    }

    private float dp(int v) {
        return v * getResources().getDisplayMetrics().density;
    }
}
