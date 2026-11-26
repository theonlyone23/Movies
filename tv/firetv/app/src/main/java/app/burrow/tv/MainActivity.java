package app.burrow.tv;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/** A full-screen WebView that opens the Burrow connect screen, then your server. */
public class MainActivity extends Activity {
    private WebView web;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#120f0d"));
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(true);
        s.setUserAgentString(s.getUserAgentString() + " AndroidTV BurrowTV/1.0");
        web.setWebViewClient(new WebViewClient());
        web.setWebChromeClient(new WebChromeClient());   // enables fullscreen video
        web.setFocusable(true);
        web.setFocusableInTouchMode(true);
        web.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION);
        setContentView(web);
        if (saved != null) web.restoreState(saved);
        else web.loadUrl("file:///android_asset/index.html");
        web.requestFocus();
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            // Let Burrow close the player / details first; exit only if it didn't.
            web.evaluateJavascript("window.burrowBack ? burrowBack() : false", handled -> {
                if (!"true".equals(handled)) finish();
            });
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        web.saveState(out);
    }
}
