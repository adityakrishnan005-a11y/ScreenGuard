#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // A lockout window is a kiosk overlay, not a normal app window: on X11 it is
  // override-redirect (no window-manager frame, cannot be moved, resized,
  // covered by the offending app, or closed through the WM).
  gboolean lockout;
  GtkWindow* window;
  guint raise_source;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Keep the overlay above everything. An override-redirect window is not
// managed by the window manager, so nothing else will raise it for us, and a
// fullscreen game can otherwise call XRaiseWindow and cover it again.
static gboolean raise_lockout_cb(gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  if (self->window != nullptr) {
    GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(self->window));
    if (gdk_window != nullptr) {
      gdk_window_raise(gdk_window);
    }
  }
  return G_SOURCE_CONTINUE;
}

static gboolean has_lockout_arg(char** args) {
  if (args == nullptr) return FALSE;
  for (int i = 0; args[i] != nullptr; i++) {
    if (g_str_has_prefix(args[i], "--times-up=") ||
        g_str_has_prefix(args[i], "--focus-block=")) {
      return TRUE;
    }
  }
  return FALSE;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));

  if (self->lockout && GTK_IS_WINDOW(toplevel)) {
    GtkWindow* window = GTK_WINDOW(toplevel);
    self->window = window;
    gtk_window_set_decorated(window, FALSE);
    gtk_window_set_keep_above(window, TRUE);
    gtk_window_set_skip_taskbar_hint(window, TRUE);
    gtk_window_set_skip_pager_hint(window, TRUE);

    GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
#ifdef GDK_WINDOWING_X11
    if (gdk_window != nullptr && GDK_IS_X11_WINDOW(gdk_window)) {
      // Must be set before the window is mapped. GTK has realized the
      // toplevel by now, so the GdkWindow exists but is still unmapped.
      gdk_window_set_override_redirect(gdk_window, TRUE);

      // With no window manager there is nobody to honour "fullscreen", so
      // size it to the monitor ourselves.
      GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
      GdkMonitor* monitor =
          gdk_display_get_monitor_at_window(display, gdk_window);
      if (monitor != nullptr) {
        GdkRectangle geometry;
        gdk_monitor_get_geometry(monitor, &geometry);
        gtk_window_move(window, geometry.x, geometry.y);
        gtk_window_set_default_size(window, geometry.width, geometry.height);
      }
    } else
#endif
    {
      // Wayland: no override-redirect; fullscreen + keep-above is the most a
      // normal client can ask for.
      gtk_window_fullscreen(window);
    }
  }

  gtk_widget_show(toplevel);

  if (self->lockout && self->window != nullptr) {
    GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(self->window));
    if (gdk_window != nullptr) {
      gdk_window_raise(gdk_window);
#ifdef GDK_WINDOWING_X11
      if (GDK_IS_X11_WINDOW(gdk_window)) {
        // Focus is not granted by any WM for an override-redirect window.
        gdk_window_focus(gdk_window, GDK_CURRENT_TIME);
      }
#endif
    }
    if (self->raise_source == 0) {
      self->raise_source =
          g_timeout_add_seconds(1, raise_lockout_cb, self);
    }
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "ScreenGuard");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "ScreenGuard");
  }

  gtk_window_set_default_icon_name("screenguard");
  gtk_window_set_icon_name(window, "screenguard");
  gtk_window_set_icon_from_file(window, "/usr/share/icons/hicolor/256x256/apps/screenguard.png", nullptr);

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);
  self->lockout = has_lockout_arg(self->dart_entrypoint_arguments);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  if (self->raise_source != 0) {
    g_source_remove(self->raise_source);
    self->raise_source = 0;
  }
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
