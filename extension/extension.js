import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import Gio from 'gi://Gio';
import Shell from 'gi://Shell';

const DBusInterface = `
<node>
  <interface name="org.gnome.Shell.Extensions.ScreenGuard">
    <method name="GetActiveWindow">
      <arg type="s" direction="out" name="app"/>
      <arg type="s" direction="out" name="title"/>
      <arg type="i" direction="out" name="pid"/>
    </method>
    <method name="MinimizeActiveWindow">
      <arg type="b" direction="out" name="success"/>
    </method>
    <method name="ListAllWindows">
      <arg type="a(ssi)" direction="out" name="windows"/>
    </method>
  </interface>
</node>`;

export default class ScreenGuardExtension extends Extension {
    enable() {
        this._dbusImpl = Gio.DBusExportedObject.wrapJSObject(DBusInterface, this);
        try {
            this._dbusImpl.export(Gio.DBus.session, '/org/gnome/Shell/Extensions/ScreenGuard');
        } catch (e) {
            console.error(`[ScreenGuard] Failed to export DBus interface: ${e}`);
        }
    }

    disable() {
        if (this._dbusImpl) {
            this._dbusImpl.unexport();
            this._dbusImpl = null;
        }
    }

    GetActiveWindow() {
        try {
            const win = global.display.focus_window;
            if (!win) {
                return ['unknown', '', 0];
            }
            
            let app = win.get_wm_class() || win.get_gtk_application_id() || '';
            
            if (!app) {
                const tracker = Shell.WindowTracker.get_default();
                const appObj = tracker.get_window_app(win);
                if (appObj) {
                    app = appObj.get_id() || appObj.get_name() || '';
                }
            }
            
            const title = win.get_title() || '';
            const pid = win.get_pid() || 0;
            
            return [app.toLowerCase(), title, pid];
        } catch (e) {
            console.error(`[ScreenGuard] Error in GetActiveWindow: ${e}`);
            return ['unknown', '', 0];
        }
    }

    MinimizeActiveWindow() {
        try {
            const win = global.display.focus_window;
            if (win) {
                win.minimize();
                return true;
            }
        } catch (e) {
            console.error(`[ScreenGuard] Error in MinimizeActiveWindow: ${e}`);
        }
        return false;
    }

    ListAllWindows() {
        try {
            const tracker = Shell.WindowTracker.get_default();
            const actors = global.get_window_actors ? global.get_window_actors() : [];
            const result = [];
            for (const actor of actors) {
                const win = actor.meta_window;
                if (!win) continue;
                let app = win.get_wm_class() || win.get_gtk_application_id() || '';
                if (!app && tracker) {
                    const appObj = tracker.get_window_app(win);
                    if (appObj) app = appObj.get_id() || appObj.get_name() || '';
                }
                const title = win.get_title() || '';
                const pid = win.get_pid() || 0;
                result.push([app.toLowerCase(), title, pid]);
            }
            return [result];
        } catch (e) {
            console.error(`[ScreenGuard] Error in ListAllWindows: ${e}`);
            return [[]];
        }
    }
}
