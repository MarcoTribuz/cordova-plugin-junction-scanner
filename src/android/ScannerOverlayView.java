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
import android.view.animation.AccelerateDecelerateInterpolator;

/**
 * Junction branded scan overlay.
 *
 * Navy-tinted dim mask, clear rounded reticle, neon-glow corner brackets,
 * accent corner dots, and an animated gradient scan-line with glow.
 * Drawn entirely in code (no resources) so the plugin stays self-contained.
 */
public class ScannerOverlayView extends View {

    private static final int ACCENT   = Color.parseColor("#3B68B2");
    private static final int NAVY_DIM = Color.parseColor("#C70A0F1E"); // ~78% navy

    private final Paint maskPaint   = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint clearPaint  = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint glowPaint   = new Paint(Paint.ANTI_ALIAS_FLAG);  // neon glow pass
    private final Paint cornerPaint = new Paint(Paint.ANTI_ALIAS_FLAG);  // crisp brackets
    private final Paint linePaint   = new Paint(Paint.ANTI_ALIAS_FLAG);
    private boolean showScanLine = false;

    private final RectF reticle = new RectF();
    private float cornerRadius;
    private float scanY;
    private ValueAnimator scanAnimator;

    public ScannerOverlayView(Context context) {
        super(context);
        // Hardware layer required for PorterDuff CLEAR (reticle punch-out).
        setLayerType(LAYER_TYPE_HARDWARE, null);

        maskPaint.setColor(NAVY_DIM);

        clearPaint.setColor(Color.TRANSPARENT);
        clearPaint.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.CLEAR));

        // Glow pass — wide soft stroke, same color but low alpha. setShadowLayer only
        // works with LAYER_TYPE_SOFTWARE; we simulate glow by drawing a thicker stroke
        // at reduced alpha before the crisp stroke.
        glowPaint.setColor(Color.parseColor("#5522D3A6")); // accent ~33% alpha
        glowPaint.setStyle(Paint.Style.STROKE);
        glowPaint.setStrokeWidth(dp(14));
        glowPaint.setStrokeCap(Paint.Cap.ROUND);
        glowPaint.setMaskFilter(null);

        cornerPaint.setColor(ACCENT);
        cornerPaint.setStyle(Paint.Style.STROKE);
        cornerPaint.setStrokeWidth(dp(3.5f));
        cornerPaint.setStrokeCap(Paint.Cap.ROUND);

        cornerRadius = dp(20);
    }

    public void setShowScanLine(boolean v) { showScanLine = v; }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        float side = Math.min(w, h) * 0.70f;
        float cx = w / 2f;
        float cy = h * 0.45f;
        reticle.set(cx - side / 2f, cy - side / 2f, cx + side / 2f, cy + side / 2f);
        if (showScanLine) startScanAnimation();
    }

    private void startScanAnimation() {
        if (scanAnimator != null) scanAnimator.cancel();
        scanAnimator = ValueAnimator.ofFloat(reticle.top + dp(8), reticle.bottom - dp(8));
        scanAnimator.setDuration(1800);
        scanAnimator.setRepeatMode(ValueAnimator.REVERSE);
        scanAnimator.setRepeatCount(ValueAnimator.INFINITE);
        scanAnimator.setInterpolator(new AccelerateDecelerateInterpolator());
        scanAnimator.addUpdateListener(a -> {
            scanY = (float) a.getAnimatedValue();
            invalidate();
        });
        scanAnimator.start();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);

        // Navy dim + reticle punch-out.
        canvas.drawRect(0, 0, getWidth(), getHeight(), maskPaint);
        canvas.drawRoundRect(reticle, cornerRadius, cornerRadius, clearPaint);

        // Subtle inner glow ring.
        Paint ringPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        RectF innerRing = new RectF(reticle.left + dp(1), reticle.top + dp(1),
                                    reticle.right - dp(1), reticle.bottom - dp(1));
        ringPaint.setStyle(Paint.Style.STROKE);
        ringPaint.setStrokeWidth(dp(2));
        ringPaint.setColor(Color.parseColor("#2622D3A6")); // accent ~15%
        canvas.drawRoundRect(innerRing, cornerRadius - dp(1), cornerRadius - dp(1), ringPaint);

        // Corner glow pass (drawn before crisp brackets).
        Path corners = buildCornersPath();
        canvas.drawPath(corners, glowPaint);

        // Crisp corner brackets.
        canvas.drawPath(corners, cornerPaint);

        if (showScanLine) drawScanLine(canvas);
    }

    private void drawScanLine(Canvas canvas) {
        float bandHalf = dp(12);
        // Glow band — wide gradient.
        LinearGradient glow = new LinearGradient(
                reticle.left, scanY - bandHalf, reticle.left, scanY + bandHalf,
                new int[]{0x0022D3A6, 0x4422D3A6, ACCENT, 0x4422D3A6, 0x0022D3A6},
                null, Shader.TileMode.CLAMP);
        linePaint.setShader(glow);
        canvas.drawRect(reticle.left + dp(6), scanY - bandHalf,
                reticle.right - dp(6), scanY + bandHalf, linePaint);

        // Sharp center line.
        float lineHalf = dp(2);
        LinearGradient sharp = new LinearGradient(
                reticle.left, scanY - lineHalf, reticle.left, scanY + lineHalf,
                new int[]{0x0022D3A6, ACCENT, ACCENT, 0x0022D3A6},
                null, Shader.TileMode.CLAMP);
        linePaint.setShader(sharp);
        canvas.drawRect(reticle.left + dp(8), scanY - lineHalf,
                reticle.right - dp(8), scanY + lineHalf, linePaint);

        linePaint.setShader(null);
    }

    private Path buildCornersPath() {
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
        return p;
    }

    @Override
    protected void onDetachedFromWindow() {
        super.onDetachedFromWindow();
        if (scanAnimator != null) scanAnimator.cancel();
    }

    private float dp(float v) {
        return v * getResources().getDisplayMetrics().density;
    }

    private float dp(int v) {
        return dp((float) v);
    }
}
