package com.murmur.mobile;

import android.util.AtomicFile;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONObject;

@CapacitorPlugin(name = "MurmurStore")
public class MurmurStorePlugin extends Plugin {
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private AtomicFile file() { return new AtomicFile(new File(getContext().getFilesDir(), "murmur-v1.json")); }
    @PluginMethod public void read(PluginCall call) {
        io.execute(() -> {
            try {
                AtomicFile file = file();
                if (!file.getBaseFile().exists() && !new File(file.getBaseFile().getPath() + ".bak").exists()) {
                    JSObject result = new JSObject(); result.put("value", JSONObject.NULL); call.resolve(result); return;
                }
                // openRead recovers a previous interrupted atomic replacement.
                try (java.io.FileInputStream stream = file.openRead()) {
                    if (stream.getChannel().size() > 8_388_608) { call.reject("Saved data is too large to open safely."); return; }
                    java.io.ByteArrayOutputStream buffer = new java.io.ByteArrayOutputStream();
                    byte[] chunk = new byte[8192]; int count;
                    while ((count = stream.read(chunk)) != -1) buffer.write(chunk, 0, count);
                    JSObject result = new JSObject(); result.put("value", buffer.toString(StandardCharsets.UTF_8.name())); call.resolve(result);
                }
            } catch (Exception error) { call.reject("Could not read saved Murmur data. It has not been changed."); }
        });
    }
    @PluginMethod public void write(PluginCall call) {
        String value = call.getString("value");
        if (value == null) { call.reject("Missing saved data."); return; }
        byte[] data = value.getBytes(StandardCharsets.UTF_8);
        if (data.length > 8_388_608) { call.reject("Murmur data exceeds the storage limit."); return; }
        io.execute(() -> {
            AtomicFile file = file(); FileOutputStream stream = null;
            try { stream = file.startWrite(); stream.write(data); file.finishWrite(stream); call.resolve(); }
            catch (Exception error) { if (stream != null) file.failWrite(stream); call.reject("Could not save Murmur data. The previous saved file is unchanged."); }
        });
    }
    @Override protected void handleOnDestroy() { io.shutdown(); }
}
