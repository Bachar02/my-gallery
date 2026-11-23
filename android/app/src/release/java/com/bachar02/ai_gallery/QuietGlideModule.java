package com.bachar02.ai_gallery;

import android.content.Context;
import android.util.Log;

import com.bumptech.glide.Glide;
import com.bumptech.glide.GlideBuilder;
import com.bumptech.glide.Registry;
import com.bumptech.glide.module.GlideModule;

/**
 * Release builds only: photo_manager decodes thumbnails with Glide, which logs
 * "Load failed for [content://media/...]" with a stack trace at WARN level for
 * every undecodable image. Raising Glide's log level to ERROR keeps MediaStore
 * ids out of logcat. Registered through the manifest (legacy GlideModule), so
 * no annotation processor is needed.
 */
@SuppressWarnings("deprecation")
public final class QuietGlideModule implements GlideModule {
    @Override
    public void applyOptions(Context context, GlideBuilder builder) {
        builder.setLogLevel(Log.ERROR);
    }

    @Override
    public void registerComponents(Context context, Glide glide,
                                   Registry registry) {
        // No custom components.
    }
}
