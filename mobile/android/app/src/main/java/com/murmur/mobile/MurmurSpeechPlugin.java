package com.murmur.mobile;

import android.Manifest;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import java.util.ArrayList;

@CapacitorPlugin(name = "MurmurSpeech", permissions = { @Permission(alias = "microphone", strings = { Manifest.permission.RECORD_AUDIO }) })
public class MurmurSpeechPlugin extends Plugin {
    private SpeechRecognizer recognizer;
    private String sessionId;
    private final Handler main = new Handler(Looper.getMainLooper());
    private Runnable timeout;
    private boolean pendingPermission = false;

    @PluginMethod public void available(PluginCall call) {
        main.post(() -> {
            boolean ready = Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(getContext());
            JSObject result = new JSObject();
            result.put("available", ready);
            result.put("reason", "On-device speech needs Android 12 or later and an installed on-device speech service. Check speech settings on this phone.");
            call.resolve(result);
        });
    }
    @PluginMethod public void start(PluginCall call) {
        main.post(() -> {
            if (sessionId != null) { call.reject("A recording is already active."); return; }
            String id = call.getString("sessionId");
            if (id == null || id.isEmpty()) { call.reject("Missing recording identifier."); return; }
            sessionId = id;
            if (getPermissionState("microphone") != PermissionState.GRANTED) {
                pendingPermission = true;
                requestPermissionForAlias("microphone", call, "microphoneResult");
            } else begin(call);
        });
    }
    @PermissionCallback private void microphoneResult(PluginCall call) {
        main.post(() -> {
            pendingPermission = false;
            if (sessionId == null || !sessionId.equals(call.getString("sessionId"))) { call.reject("Recording cancelled."); return; }
            if (getPermissionState("microphone") != PermissionState.GRANTED) {
                release(); call.reject("Allow microphone access for Murmur in Android Settings to dictate.");
            } else begin(call);
        });
    }
    private void begin(PluginCall call) {
        if (Build.VERSION.SDK_INT < 31 || !SpeechRecognizer.isOnDeviceRecognitionAvailable(getContext())) {
            release(); call.reject("On-device speech recognition is unavailable on this phone. No audio was sent to the cloud."); return;
        }
        final String id = sessionId;
        try {
            recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(getContext());
            recognizer.setRecognitionListener(new RecognitionListener() {
                private boolean current() { return id.equals(sessionId); }
                public void onReadyForSpeech(Bundle params) { if (current()) state(id, "recording"); }
                public void onBeginningOfSpeech() {}
                public void onRmsChanged(float rmsdB) {}
                public void onBufferReceived(byte[] buffer) {}
                public void onEndOfSpeech() { if (current()) { state(id, "finishing"); deadline(id, 10000); } }
                public void onError(int error) {
                    if (!current()) return;
                    String message;
                    switch (error) {
                        case SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS: message = "Microphone access was denied. Allow it in Android Settings."; break;
                        case SpeechRecognizer.ERROR_NO_MATCH: case SpeechRecognizer.ERROR_SPEECH_TIMEOUT: message = "No clear speech was recognized. Try speaking a little closer to the microphone."; break;
                        case SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED: case SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE: message = "This speech language is not installed or supported. Check your phone’s speech settings or choose another language."; break;
                        case SpeechRecognizer.ERROR_RECOGNIZER_BUSY: message = "The speech service is busy. Wait a moment and try again."; break;
                        default: message = "Speech recognition stopped. Your latest words are kept. Try again when you’re ready.";
                    }
                    fail(message);
                }
                public void onResults(Bundle results) { if (current()) { result(id, results, true); release(); } }
                public void onPartialResults(Bundle results) { if (current()) result(id, results, false); }
                public void onEvent(int eventType, Bundle params) {}
            });
            Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
            intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
            intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, call.getString("locale", "en-US"));
            intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
            intent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1);
            // createOnDeviceSpeechRecognizer is the privacy guarantee; PREFER_OFFLINE alone is not.
            if (Build.VERSION.SDK_INT >= 33) {
                JSArray values = call.getArray("hints", new JSArray());
                ArrayList<String> hints = new ArrayList<>();
                for (int i = 0; i < Math.min(values.length(), 80); i++) {
                    String value = values.optString(i, "");
                    if (!value.isEmpty() && value.length() <= 80) hints.add(value);
                }
                intent.putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, hints);
            }
            recognizer.startListening(intent);
            state(id, "recording");
            deadline(id, 65000);
            call.resolve();
        } catch (Exception error) { release(); call.reject("Could not start on-device speech. Check the microphone and speech service settings."); }
    }
    private void result(String id, Bundle bundle, boolean done) {
        ArrayList<String> values = bundle.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        if (values == null || values.isEmpty()) {
            if (done) fail("No words were recognized. Try again; your latest draft is kept.");
            return;
        }
        JSObject event = new JSObject(); event.put("sessionId", id); event.put("text", values.get(0)); event.put("final", done);
        notifyListeners("result", event);
    }
    private void state(String id, String value) {
        JSObject event = new JSObject(); event.put("sessionId", id); event.put("state", value); notifyListeners("state", event);
    }
    private void deadline(String id, long duration) {
        if (timeout != null) main.removeCallbacks(timeout);
        timeout = () -> { if (id.equals(sessionId)) fail("Recognition took too long. Your latest words are kept in the draft."); };
        main.postDelayed(timeout, duration);
    }
    @PluginMethod public void stop(PluginCall call) {
        main.post(() -> {
            try {
                if (recognizer != null && sessionId != null) { recognizer.stopListening(); state(sessionId, "finishing"); deadline(sessionId, 10000); }
            } catch (Exception error) { fail("Could not finish recognition. Your latest words are kept."); }
            call.resolve();
        });
    }
    @PluginMethod public void cancel(PluginCall call) {
        main.post(() -> { String id = sessionId; release(); if (id != null) state(id, "idle"); call.resolve(); });
    }
    private void fail(String message) {
        String id = sessionId; release();
        if (id != null) { JSObject event = new JSObject(); event.put("sessionId", id); event.put("message", message); notifyListeners("failure", event); }
    }
    private void release() {
        sessionId = null;
        if (timeout != null) { main.removeCallbacks(timeout); timeout = null; }
        if (recognizer != null) { recognizer.cancel(); recognizer.destroy(); recognizer = null; }
    }
    @Override protected void handleOnPause() {
        if (!pendingPermission) main.post(() -> { if (sessionId != null) fail("Recording stopped when Murmur left the foreground. Your latest words are kept."); });
    }
    @Override protected void handleOnStop() {
        main.post(() -> { if (sessionId != null) fail("Recording stopped when Murmur left the foreground. Your latest words are kept."); });
    }
    @Override protected void handleOnDestroy() { main.post(this::release); }
}
