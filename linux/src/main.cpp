// gPTP Studio — Rivet GTK4 host.
//
// First-party GTK4 shell over one embedded Racket CS backend. Six pages:
// Engine (live curves through the shared chart widget), Qualification,
// Packets (list + hex/PTP detail), Logs, GM Tuning, License & Settings.
// All widget access stays on the GLib main loop; RVT1 event callbacks and
// async completions arrive on the reader thread and are dispatched with
// g_idle_add before touching GTK.

#include <gtk/gtk.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <mutex>
#include <functional>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "GeneratedBackend.hpp"
#include "chart_area.hpp"
#include "theme.hpp"

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

namespace {

// ---- app state -----------------------------------------------------------

struct AppState {
  GtkWindow* window{nullptr};
  GtkStack* stack{nullptr};
  GtkLabel* status{nullptr};
  GtkLabel* alarm_line{nullptr};

  // Engine page
  GtkDropDown* role{nullptr};
  GtkDropDown* mode{nullptr};
  GtkEntry* iface{nullptr};
  GtkButton* start{nullptr};
  GtkButton* stop{nullptr};
  GtkLabel* offset_value{nullptr};
  GtkLabel* delay_value{nullptr};
  GtkLabel* gm_value{nullptr};
  GtkLabel* port_value{nullptr};
  GtkLabel* engine_state_value{nullptr};
  GtkLabel* processes_value{nullptr};
  std::unique_ptr<rivet::ui::ChartArea> chart;

  // Qualification page
  GtkDropDown* qual_iface{nullptr};
  GtkButton* qual_run{nullptr};
  GtkTextView* qual_report{nullptr};

  // Packets page
  GtkEntry* capture_iface{nullptr};
  GtkButton* capture_start{nullptr};
  GtkButton* capture_stop{nullptr};
  GtkButton* pcap_import{nullptr};
  GtkButton* pcap_export{nullptr};
  GtkButton* wireshark_live{nullptr};
  GtkButton* packets_clear{nullptr};
  GtkListBox* packet_list{nullptr};
  GtkTextView* packet_detail{nullptr};
  GtkLabel* packet_count{nullptr};
  std::vector<rivet_app::PacketRow> packet_rows;

  // Logs page
  GtkTextView* log_view{nullptr};
  GtkButton* log_export{nullptr};

  // Tuning page
  GtkButton* gm_apply{nullptr};
  std::vector<std::pair<std::string, GtkSpinButton*>> gm_spin;

  // License page
  GtkLabel* gate_value{nullptr};
  GtkButton* trial_start{nullptr};
  GtkEntry* license_path{nullptr};
  GtkButton* activate{nullptr};
  GtkButton* deactivate{nullptr};
  GtkButton* report_export{nullptr};
  GtkButton* diagnostics_export{nullptr};

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;
  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};

  void set_status(std::string const& text) {
    gtk_label_set_text(GTK_LABEL(status), text.c_str());
  }
};

AppState g_state;

// ---- utilities ------------------------------------------------------------

std::filesystem::path executable_path() {
#if defined(__APPLE__)
  uint32_t size = 0;
  _NSGetExecutablePath(nullptr, &size);
  std::string buffer(size, '\0');
  _NSGetExecutablePath(buffer.data(), &size);
  return std::filesystem::canonical(buffer);
#else
  return std::filesystem::read_symlink("/proc/self/exe");
#endif
}

void idle_deliver(std::function<void()> work) {
  g_idle_add(
      [](gpointer data) -> gboolean {
        auto* owned = static_cast<std::function<void()>*>(data);
        (*owned)();
        delete owned;
        return G_SOURCE_REMOVE;
      },
      new std::function<void()>(std::move(work)));
}

std::string value_text(rivet::Value const& value) {
  struct Visitor {
    std::string operator()(std::monostate) const { return "—"; }
    std::string operator()(bool v) const { return v ? "yes" : "no"; }
    std::string operator()(std::int64_t v) const { return std::to_string(v); }
    std::string operator()(std::string const& v) const { return v; }
    std::string operator()(rivet::Bytes const&) const { return "<bytes>"; }
    std::string operator()(rivet::Value::List const& v) const {
      return "(" + std::to_string(v.size()) + " items)";
    }
  };
  return std::visit(Visitor{}, value.data);
}

std::string format_offset(std::int64_t ns) {
  char buffer[64];
  double magnitude = static_cast<double>(ns < 0 ? -ns : ns);
  if (magnitude >= 1e6) {
    std::snprintf(buffer, sizeof(buffer), "%.2f ms", static_cast<double>(ns) / 1e6);
  } else if (magnitude >= 1e3) {
    std::snprintf(buffer, sizeof(buffer), "%.1f us", static_cast<double>(ns) / 1e3);
  } else {
    std::snprintf(buffer, sizeof(buffer), "%lld ns", static_cast<long long>(ns));
  }
  return buffer;
}

std::string packet_summary_line(rivet_app::PacketRow const& row) {
  std::string time = std::to_string(row.ts.seconds) + "." +
                     std::to_string(row.ts.nanoseconds);
  return "#" + std::to_string(row.frame_no) + "  " + time + "  " + row.summary;
}

// PTP detail: render the open decode tree as readable lines.
void append_value_tree(std::string& out, rivet::Value const& value, int depth) {
  std::string indent(static_cast<std::size_t>(depth) * 2, ' ');
  if (auto const* list = std::get_if<rivet::Value::List>(&value.data)) {
    for (auto const& item : *list) {
      append_value_tree(out, item, depth);
    }
    return;
  }
  if (auto const* text = std::get_if<std::string>(&value.data)) {
    out += indent + *text + "\n";
    return;
  }
  out += indent + value_text(value) + "\n";
}

std::string packet_detail_text(rivet_app::PacketRow const& row) {
  std::string out;
  out += "frame      #" + std::to_string(row.frame_no) + "\n";
  out += "interface  " + row.iface + "\n";
  out += "source     " + row.source + "\n";
  if (row.mac_src.has_value()) {
    out += "mac src    " + *row.mac_src + "\n";
  }
  if (row.mac_dst.has_value()) {
    out += "mac dst    " + *row.mac_dst + "\n";
  }
  out += "ethertype  " + row.ethertype_hex + "\n";
  out += "transport  " + (row.transport.has_value() ? *row.transport : "—") + "\n";
  out += "length     " + std::to_string(row.length) + "\n";
  if (row.error.has_value() && !row.error->empty()) {
    out += "error      " + *row.error + "\n";
  }
  out += "\n--- decoded PTP ---\n";
  append_value_tree(out, row.ptp, 0);
  out += "\n--- hex ---\n";
  out += row.raw_hex;
  return out;
}

// ---- backend lifecycle ----------------------------------------------------

struct RuntimeLayout {
  std::filesystem::path petite_boot;
  std::filesystem::path scheme_boot;
  std::filesystem::path racket_boot;
  std::filesystem::path core;
};

std::optional<RuntimeLayout> discover_runtime_layout() {
  auto const root = executable_path().parent_path();
  RuntimeLayout layout{root / "runtime/petite.boot", root / "runtime/scheme.boot",
                       root / "runtime/racket.boot", root / "res/core.zo"};
  if (std::filesystem::exists(layout.petite_boot) &&
      std::filesystem::exists(layout.scheme_boot) &&
      std::filesystem::exists(layout.racket_boot) &&
      std::filesystem::exists(layout.core)) {
    return layout;
  }
  return std::nullopt;
}

void refresh_engine_labels(rivet_app::EngineStatus const& status);
void refresh_capture_buttons(rivet_app::CaptureStatus const& status);
void repull_series(std::string const& series);
void repull_packets();
void repull_logs();

void on_start_clicked(GtkButton*, gpointer);

int on_backend_finished(gpointer) {
  std::lock_guard lock(g_state.startup_mutex);
  if (!g_state.startup_error.empty()) {
    g_state.set_status("Backend failed: " + g_state.startup_error);
    return G_SOURCE_REMOVE;
  }
  g_state.backend = std::move(g_state.startup_backend);
  g_state.api = std::make_unique<rivet_app::API>(*g_state.backend);
  g_state.set_status("Embedded Racket CS is ready");
  (void)g_state.api->bootstrap_async([](rivet_app::Result<rivet_app::Bootstrap> result) {
    if (result.error) {
      return;
    }
    auto const value = result.get();
    idle_deliver([value] {
      g_state.set_status("gPTP Studio " + value.version + " — " + value.platform);
      refresh_engine_labels(value.engine);
      refresh_capture_buttons(value.capture);
      gtk_editable_set_text(GTK_EDITABLE(g_state.iface),
                            value.capture_iface.has_value() ? value.capture_iface->c_str() : "");
      gtk_editable_set_text(GTK_EDITABLE(g_state.capture_iface),
                            value.capture_iface.has_value() ? value.capture_iface->c_str() : "");
      auto warn_us = value.offset_warn_us;
      std::vector<rivet::ui::ChartThreshold> thresholds;
      if (warn_us > 0) {
        thresholds.push_back({warn_us * 1000, "alarm high", "#f5c211"});
        thresholds.push_back({-warn_us * 1000, "alarm low", "#f5c211"});
      }
      g_state.chart->set_thresholds(std::move(thresholds));
      std::string gate = value.gate.tier;
      gate += value.gate.pro ? " (Pro)" : "";
      gtk_label_set_text(g_state.gate_value, gate.c_str());
    });
  });
  repull_series("offset");
  repull_series("delay");
  repull_packets();
  repull_logs();
  // Dev-build verification hook: auto-start the simulator so headless
  // captures can assert the chart pipeline without synthetic input events.
  // Never active in packaged builds (the variable is not set there).
  if (std::getenv("GPTP_DEV_AUTOSTART") != nullptr) {
    gtk_drop_down_set_selected(g_state.role, 1);  // slave: both curves move
    on_start_clicked(nullptr, nullptr);
  }
  return G_SOURCE_REMOVE;
}

void start_backend() {
  auto layout = discover_runtime_layout();
  if (!layout) {
    g_state.set_status("Missing runtime/*.boot and res/core.zo next to the executable");
    return;
  }
  rivet::linux_runtime::RacketRuntimeConfig config;
  config.executable_path = executable_path().string();
  config.petite_boot = layout->petite_boot.string();
  config.scheme_boot = layout->scheme_boot.string();
  config.racket_boot = layout->racket_boot.string();
  config.backend_bundle = layout->core.string();
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;

  g_state.startup_thread = std::thread([config = std::move(config)]() mutable {
    auto backend = std::make_unique<rivet::linux_runtime::Backend>(std::move(config));
    backend->set_event_handler([](std::string const& name, rivet::Value const& value) {
      try {
        auto event = rivet_app::decode_event(name, value);
        if (auto state = std::get_if<rivet_app::Engine_stateEvent>(&event)) {
          auto status = state->value;
          idle_deliver([status] { refresh_engine_labels(status); });
        }
        if (auto batch = std::get_if<rivet_app::Chart_batchEvent>(&event)) {
          auto envelope = batch->value;
          idle_deliver([envelope] {
            if (g_state.chart) {
              g_state.chart->append_batch(envelope.series, envelope.batch);
            }
          });
        }
        if (auto packets = std::get_if<rivet_app::Packets_appendedEvent>(&event)) {
          auto rows = packets->value;
          idle_deliver([rows] {
            for (auto const& row : rows) {
              g_state.packet_rows.push_back(row);
              GtkWidget* row_widget = gtk_label_new(packet_summary_line(row).c_str());
              gtk_label_set_xalign(GTK_LABEL(row_widget), 0.0F);
              gtk_widget_add_css_class(row_widget, "monospace");
              gtk_list_box_append(g_state.packet_list, row_widget);
            }
            auto stored = static_cast<long long>(g_state.packet_rows.size());
            gtk_label_set_text(
                g_state.packet_count,
                (std::to_string(stored) + " shown (newest last)").c_str());
          });
        }
        if (std::get_if<rivet_app::Packets_clearedEvent>(&event)) {
          idle_deliver([] {
            g_state.packet_rows.clear();
            GtkListBoxRow* child = gtk_list_box_get_row_at_index(g_state.packet_list, 0);
            while (child != nullptr) {
              gtk_list_box_remove(g_state.packet_list, GTK_WIDGET(child));
              child = gtk_list_box_get_row_at_index(g_state.packet_list, 0);
            }
            gtk_label_set_text(g_state.packet_count, "0 shown");
          });
        }
        if (auto capture = std::get_if<rivet_app::Capture_state_changedEvent>(&event)) {
          auto status = capture->value;
          idle_deliver([status] { refresh_capture_buttons(status); });
        }
        if (auto alarm = std::get_if<rivet_app::Alarm_eventEvent>(&event)) {
          auto payload = alarm->value;
          idle_deliver([payload] {
            gtk_label_set_text(g_state.alarm_line, payload.message.c_str());
          });
        }
        if (auto error = std::get_if<rivet_app::Backend_errorEvent>(&event)) {
          auto message = error->value;
          idle_deliver([message] { g_state.set_status("Backend: " + message); });
        }
      } catch (...) {
      }
    });
    try {
      backend->start();
      std::lock_guard lock(g_state.startup_mutex);
      g_state.startup_backend = std::move(backend);
    } catch (std::exception const& error) {
      std::lock_guard lock(g_state.startup_mutex);
      g_state.startup_error = error.what();
    }
    g_idle_add(on_backend_finished, nullptr);
  });
}

// ---- refresh helpers ------------------------------------------------------

void refresh_engine_labels(rivet_app::EngineStatus const& status) {
  std::string offset = value_text(status.offset_ns);
  char* end = nullptr;
  long long parsed = std::strtoll(offset.c_str(), &end, 10);
  if (end != nullptr && *end == '\0') {
    offset = format_offset(parsed);
  }
  gtk_label_set_text(g_state.offset_value, offset.c_str());
  gtk_label_set_text(g_state.delay_value, value_text(status.delay_ns).c_str());
  gtk_label_set_text(g_state.gm_value, value_text(status.gm_id).c_str());
  gtk_label_set_text(g_state.port_value, value_text(status.port_state).c_str());
  std::string state_text = status.role + " / " + status.mode + " / " + status.reference;
  if (status.last_failure.has_value()) {
    state_text += "  (last failure: " + *status.last_failure + ")";
  }
  gtk_label_set_text(g_state.engine_state_value, state_text.c_str());
  std::string processes;
  for (auto const& process : status.processes) {
    if (!processes.empty()) {
      processes += "  ";
    }
    processes += process.name + (process.running ? ": running" : ": stopped");
  }
  gtk_label_set_text(g_state.processes_value, processes.c_str());
}

void refresh_capture_buttons(rivet_app::CaptureStatus const& status) {
  std::string text = status.running ? "capturing" : "idle";
  if (status.iface.has_value()) {
    text += " on " + *status.iface;
  }
  if (status.timestamp_source.has_value()) {
    text += " (" + *status.timestamp_source + ")";
  }
  gtk_button_set_label(g_state.capture_start, status.running ? "Restart Capture" : "Start Capture");
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.capture_stop), status.running);
  g_state.set_status(text);
}

void repull_series(std::string const& series) {
  if (g_state.api == nullptr) {
    return;
  }
  (void)g_state.api->series_window_async(
      series, [series](rivet_app::Result<rivet_app::SeriesWindow> result) {
        if (result.error) {
          return;
        }
        auto const window = result.get();
        idle_deliver([series, window] {
          if (!g_state.chart) {
            return;
          }
          try {
            auto batch = rivet::chart::DecodeBatch(window.samples);
            g_state.chart->replace_series(
                series, std::move(batch.samples),
                static_cast<std::uint64_t>(window.watermark));
          } catch (std::runtime_error const&) {
          }
        });
      });
}

void repull_packets() {
  if (g_state.api == nullptr) {
    return;
  }
  (void)g_state.api->packets_page_async(
      200, [](rivet_app::Result<rivet_app::PacketPage> result) {
        if (result.error) {
          return;
        }
        auto const page = result.get();
        idle_deliver([page] {
          g_state.packet_rows.assign(page.rows.begin(), page.rows.end());
          GtkListBoxRow* child = gtk_list_box_get_row_at_index(g_state.packet_list, 0);
          while (child != nullptr) {
            gtk_list_box_remove(g_state.packet_list, GTK_WIDGET(child));
            child = gtk_list_box_get_row_at_index(g_state.packet_list, 0);
          }
          for (auto const& row : page.rows) {
            GtkWidget* row_widget = gtk_label_new(packet_summary_line(row).c_str());
            gtk_label_set_xalign(GTK_LABEL(row_widget), 0.0F);
            gtk_widget_add_css_class(row_widget, "monospace");
            gtk_list_box_append(g_state.packet_list, row_widget);
          }
          gtk_label_set_text(
              g_state.packet_count,
              (std::to_string(static_cast<long long>(page.stored)) + " stored / " +
               std::to_string(static_cast<long long>(page.total)) + " total")
                  .c_str());
        });
      });
}

void repull_logs() {
  if (g_state.api == nullptr) {
    return;
  }
  (void)g_state.api->logs_async([](rivet_app::Result<std::vector<rivet_app::LogRow>> result) {
    if (result.error) {
      return;
    }
    auto const rows = result.get();
    idle_deliver([rows] {
      auto* buffer = gtk_text_view_get_buffer(g_state.log_view);
      std::string text;
      for (auto const& row : rows) {
        text += "[" + row.source + "/" + row.level + "] " + row.message + "\n";
      }
      gtk_text_buffer_set_text(buffer, text.c_str(), static_cast<int>(text.size()));
    });
  });
}

// ---- action handlers ------------------------------------------------------

std::string dropdown_text(GtkDropDown* dropdown) {
  auto* item = gtk_drop_down_get_selected_item(dropdown);
  if (item == nullptr) {
    return {};
  }
  auto const value = gtk_string_object_get_string(GTK_STRING_OBJECT(item));
  return value != nullptr ? value : "";
}

void on_start_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  std::string role = dropdown_text(g_state.role);
  std::string mode = dropdown_text(g_state.mode);
  std::string iface = gtk_editable_get_text(GTK_EDITABLE(g_state.iface));
  (void)g_state.api->engine_start_async(
      role, mode, iface, std::vector<std::string>{},
      [](rivet_app::Result<rivet_app::EngineStartResult> result) {
        if (result.error) {
          return;
        }
        auto const value = result.get();
        idle_deliver([value] {
          if (value.ok) {
            g_state.set_status("engine started");
          } else if (value.need_pro) {
            g_state.set_status("Pro required: " + value.error.value_or(""));
          } else {
            g_state.set_status("engine start failed: " + value.error.value_or("?"));
          }
          if (value.status.has_value()) {
            refresh_engine_labels(*value.status);
          }
        });
      });
}

void on_stop_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  (void)g_state.api->engine_stop_async([](rivet_app::Result<rivet_app::EngineStatus> result) {
    if (result.error) {
      return;
    }
    auto const status = result.get();
    idle_deliver([status] {
      g_state.set_status("engine stopped");
      refresh_engine_labels(status);
    });
  });
}

void on_qual_run_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  std::string iface = dropdown_text(g_state.qual_iface);
  (void)g_state.api->qualify_async(
      iface, "listener", "system", std::vector<std::string>{},
      [](rivet_app::Result<rivet_app::ActionResult> result) {
        if (result.error) {
          return;
        }
        auto const value = result.get();
        idle_deliver([value] {
          auto* buffer = gtk_text_view_get_buffer(g_state.qual_report);
          std::string text = value.ok ? value_text(value.info) : ("failed: " + value.error.value_or("?"));
          gtk_text_buffer_set_text(buffer, text.c_str(), static_cast<int>(text.size()));
        });
      });
}

void on_capture_start_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  std::string iface = gtk_editable_get_text(GTK_EDITABLE(g_state.capture_iface));
  (void)g_state.api->capture_start_async(
      iface, [](rivet_app::Result<rivet_app::ActionResult> result) {
        if (result.error) {
          return;
        }
        auto const value = result.get();
        idle_deliver([value] {
          g_state.set_status(value.ok ? "capture started" : ("capture failed: " + value.error.value_or("?")));
        });
      });
}

void on_capture_stop_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  (void)g_state.api->capture_stop_async([](rivet_app::Result<rivet_app::CaptureStatus>) {});
}

void on_packets_clear_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  (void)g_state.api->packets_clear_async([](rivet_app::Result<bool>) {});
}

void on_gm_apply_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  std::optional<std::int64_t> values[13];
  std::size_t index = 0;
  for (auto const& [name, spin] : g_state.gm_spin) {
    (void)name;
    values[index++] = static_cast<std::int64_t>(gtk_spin_button_get_value_as_int(spin));
  }
  (void)g_state.api->gm_settings_apply_async(
      values[0], values[1], values[2], values[3], values[4], values[5], values[6],
      values[7], values[8], values[9], values[10], values[11], values[12],
      [](rivet_app::Result<rivet_app::ActionResult> result) {
        if (result.error) {
          return;
        }
        auto const value = result.get();
        idle_deliver([value] {
          g_state.set_status(value.ok ? "GM settings applied"
                                      : ("GM tuning: " + value.error.value_or("?")));
        });
      });
}

void on_trial_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  (void)g_state.api->license_trial_start_async(
      [](rivet_app::Result<rivet_app::GateInfo> result) {
        if (result.error) {
          return;
        }
        auto const gate = result.get();
        idle_deliver([gate] {
          gtk_label_set_text(g_state.gate_value, (gate.tier + " (trial)").c_str());
        });
      });
}

void on_activate_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  std::string path = gtk_editable_get_text(GTK_EDITABLE(g_state.license_path));
  (void)g_state.api->license_activate_async(
      path, [](rivet_app::Result<rivet_app::ActionResult> result) {
        if (result.error) {
          return;
        }
        auto const value = result.get();
        idle_deliver([value] {
          g_state.set_status(value.ok ? "license activated" : ("license: " + value.error.value_or("?")));
          (void)g_state.api->license_status_async([](rivet_app::Result<rivet_app::GateInfo> gate) {
            if (gate.error) {
              return;
            }
            auto const info = gate.get();
            idle_deliver([info] {
              gtk_label_set_text(g_state.gate_value, (info.tier + (info.pro ? " (Pro)" : "")).c_str());
            });
          });
        });
      });
}

void on_deactivate_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  (void)g_state.api->license_deactivate_async(
      [](rivet_app::Result<rivet_app::GateInfo> result) {
        if (result.error) {
          return;
        }
        auto const gate = result.get();
        idle_deliver([gate] {
          gtk_label_set_text(g_state.gate_value, gate.tier.c_str());
        });
      });
}

// Host-owned export flows: the native file dialog runs here, then the chosen
// path goes back through the typed RPC (the dialog never lived in the
// backend under Rivet — see docs/chart-series.md's sibling conventions).
void save_file_dialog_path(char const* title, char const* default_name,
                           std::function<void(std::string)> completion) {
  auto* dialog = gtk_file_dialog_new();
  gtk_file_dialog_set_title(dialog, title);
  if (default_name != nullptr) {
    auto* initial = g_file_new_for_path(default_name);
    gtk_file_dialog_set_initial_file(dialog, initial);
    g_object_unref(initial);
  }
  struct Request {
    GtkFileDialog* dialog;
    std::function<void(std::string)> completion;
  };
  auto* request = new Request{dialog, std::move(completion)};
  gtk_file_dialog_save(
      dialog, g_state.window, nullptr,
      [](GObject* source, GAsyncResult* result, gpointer user_data) {
        std::unique_ptr<Request> owned(static_cast<Request*>(user_data));
        auto* file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, nullptr);
        std::string path = file != nullptr ? g_file_get_path(file) : std::string();
        if (file != nullptr) {
          g_object_unref(file);
        }
        owned->completion(path);
        g_object_unref(owned->dialog);
      },
      request);
}

void open_file_dialog_path(char const* title, std::function<void(std::string)> completion) {
  auto* dialog = gtk_file_dialog_new();
  gtk_file_dialog_set_title(dialog, title);
  struct Request {
    GtkFileDialog* dialog;
    std::function<void(std::string)> completion;
  };
  auto* request = new Request{dialog, std::move(completion)};
  gtk_file_dialog_open(
      dialog, g_state.window, nullptr,
      [](GObject* source, GAsyncResult* result, gpointer user_data) {
        std::unique_ptr<Request> owned(static_cast<Request*>(user_data));
        auto* file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, nullptr);
        std::string path = file != nullptr ? g_file_get_path(file) : std::string();
        if (file != nullptr) {
          g_object_unref(file);
        }
        owned->completion(path);
        g_object_unref(owned->dialog);
      },
      request);
}

void on_pcap_import_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  open_file_dialog_path("Import pcap / pcapng", [](std::string path) {
    if (path.empty() || g_state.api == nullptr) {
      return;
    }
    (void)g_state.api->pcap_import_async(path, [](rivet_app::Result<rivet_app::ActionResult> result) {
      if (result.error) {
        return;
      }
      auto const value = result.get();
      idle_deliver([value] {
        g_state.set_status(value.ok ? ("imported " + value_text(value.info) + " packets")
                                    : ("import failed: " + value.error.value_or("?")));
        repull_packets();
      });
    });
  });
}

void on_pcap_export_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  save_file_dialog_path(
      "Export pcap", "gptp-studio-capture.pcap", [](std::string path) {
        if (path.empty() || g_state.api == nullptr) {
          return;
        }
        (void)g_state.api->pcap_export_async(
            path, [](rivet_app::Result<rivet_app::ActionResult> result) {
              if (result.error) {
                return;
              }
              auto const value = result.get();
              idle_deliver([value] {
                g_state.set_status(value.ok ? "pcap exported"
                                            : ("export: " + value.error.value_or("?")));
              });
            });
      });
}

void on_wireshark_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  std::string iface = gtk_editable_get_text(GTK_EDITABLE(g_state.capture_iface));
  (void)g_state.api->wireshark_launch_async(
      "live", iface, [](rivet_app::Result<rivet_app::ActionResult> result) {
        if (result.error) {
          return;
        }
        auto const value = result.get();
        idle_deliver([value] {
          g_state.set_status(value.ok ? "wireshark launched" : ("wireshark: " + value.error.value_or("?")));
        });
      });
}

void on_log_export_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  save_file_dialog_path(
      "Export logs", "gptp-studio.log", [](std::string path) {
        if (path.empty() || g_state.api == nullptr) {
          return;
        }
        (void)g_state.api->logs_export_async(
            path, [](rivet_app::Result<rivet_app::ActionResult>) {});
      });
}

void on_report_export_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  save_file_dialog_path(
      "Export engineering report", "gptp-studio-report.json", [](std::string path) {
        if (path.empty() || g_state.api == nullptr) {
          return;
        }
        (void)g_state.api->report_export_async(
            path, "", "", "system", [](rivet_app::Result<rivet_app::ActionResult> result) {
              if (result.error) {
                return;
              }
              auto const value = result.get();
              idle_deliver([value] {
                g_state.set_status(value.ok ? "report exported"
                                            : ("report: " + value.error.value_or("?")));
              });
            });
      });
}

void on_diagnostics_export_clicked(GtkButton*, gpointer) {
  save_file_dialog_path(
      "Export diagnostics snapshot", "gptp-studio-diagnostics.json",
      [](std::string path) {
        if (path.empty() || g_state.api == nullptr) {
          return;
        }
        (void)g_state.api->diagnostics_export_async(
            path, "", "listener", "system",
            [](rivet_app::Result<rivet_app::ActionResult> result) {
              if (result.error) {
                return;
              }
              auto const value = result.get();
              idle_deliver([value] {
                g_state.set_status(value.ok ? "diagnostics exported"
                                            : ("diagnostics: " + value.error.value_or("?")));
              });
            });
      });
}

void on_packet_row_selected(GtkListBox*, GtkListBoxRow* row, gpointer) {
  if (row == nullptr) {
    return;
  }
  guint index = gtk_list_box_row_get_index(row);
  if (index >= g_state.packet_rows.size()) {
    return;
  }
  auto const& packet = g_state.packet_rows[index];
  std::string text = packet_detail_text(packet);
  auto* buffer = gtk_text_view_get_buffer(g_state.packet_detail);
  gtk_text_buffer_set_text(buffer, text.c_str(), static_cast<int>(text.size()));
}

// ---- page construction ----------------------------------------------------

GtkWidget* info_row(char const* caption, GtkLabel** out) {
  auto* box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
  auto* label = gtk_label_new(caption);
  gtk_widget_add_css_class(label, "dim-label");
  auto* value = gtk_label_new("—");
  gtk_label_set_xalign(GTK_LABEL(value), 0.0F);
  gtk_box_append(GTK_BOX(box), label);
  gtk_box_append(GTK_BOX(box), value);
  gtk_widget_set_hexpand(value, TRUE);
  if (out != nullptr) {
    *out = GTK_LABEL(value);
  }
  return box;
}

GtkWidget* build_engine_page() {
  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);

  auto* controls = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  auto* role_label = gtk_label_new("Role");
  const char* roles[] = {"grandmaster", "slave", "listener", "boundary", nullptr};
  auto* role = gtk_drop_down_new_from_strings(roles);
  gtk_drop_down_set_selected(GTK_DROP_DOWN(role), 2);
  auto* mode_label = gtk_label_new("Mode");
  const char* modes[] = {"sim", "real", nullptr};
  auto* mode = gtk_drop_down_new_from_strings(modes);
  auto* iface_label = gtk_label_new("Interface");
  auto* iface = gtk_entry_new();
  gtk_entry_set_placeholder_text(GTK_ENTRY(iface), "e.g. eth0");
  gtk_widget_set_size_request(iface, 160, -1);
  auto* start = gtk_button_new_with_label("Start Engine");
  auto* stop = gtk_button_new_with_label("Stop Engine");
  gtk_widget_add_css_class(start, "suggested-action");
  gtk_box_append(GTK_BOX(controls), role_label);
  gtk_box_append(GTK_BOX(controls), role);
  gtk_box_append(GTK_BOX(controls), mode_label);
  gtk_box_append(GTK_BOX(controls), mode);
  gtk_box_append(GTK_BOX(controls), iface_label);
  gtk_box_append(GTK_BOX(controls), iface);
  gtk_box_append(GTK_BOX(controls), start);
  gtk_box_append(GTK_BOX(controls), stop);

  g_state.role = GTK_DROP_DOWN(role);
  g_state.mode = GTK_DROP_DOWN(mode);
  g_state.iface = GTK_ENTRY(iface);
  g_state.start = GTK_BUTTON(start);
  g_state.stop = GTK_BUTTON(stop);

  auto* metrics = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  gtk_box_append(GTK_BOX(metrics), info_row("offsetFromMaster", &g_state.offset_value));
  gtk_box_append(GTK_BOX(metrics), info_row("meanPathDelay", &g_state.delay_value));
  gtk_box_append(GTK_BOX(metrics), info_row("grandmaster", &g_state.gm_value));
  gtk_box_append(GTK_BOX(metrics), info_row("port state", &g_state.port_value));
  gtk_box_append(GTK_BOX(metrics), info_row("engine", &g_state.engine_state_value));
  gtk_box_append(GTK_BOX(metrics), info_row("processes", &g_state.processes_value));
  auto* alarm = gtk_label_new("");
  gtk_label_set_xalign(GTK_LABEL(alarm), 0.0F);
  gtk_widget_add_css_class(alarm, "warning");
  g_state.alarm_line = GTK_LABEL(alarm);
  gtk_box_append(GTK_BOX(metrics), alarm);

  g_state.chart = std::make_unique<rivet::ui::ChartArea>();
  g_state.chart->set_series({{"offset", "offsetFromMaster", "#3584e4", "ns"},
                             {"delay", "meanPathDelay", "#e01b24", "ns"}});
  g_state.chart->set_title("sync convergence");
  g_state.chart->on_gap = [](std::string const& series) { repull_series(series); };
  gtk_widget_set_vexpand(g_state.chart->widget(), TRUE);
  gtk_widget_set_size_request(g_state.chart->widget(), -1, 260);

  auto* chart_frame = gtk_frame_new("Live timing series");
  gtk_frame_set_child(GTK_FRAME(chart_frame), g_state.chart->widget());

  gtk_box_append(GTK_BOX(box), controls);
  gtk_box_append(GTK_BOX(box), metrics);
  gtk_box_append(GTK_BOX(box), chart_frame);

  g_signal_connect(start, "clicked", G_CALLBACK(on_start_clicked), nullptr);
  g_signal_connect(stop, "clicked", G_CALLBACK(on_stop_clicked), nullptr);
  return box;
}

GtkWidget* build_qualification_page() {
  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  auto* controls = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  auto* iface_label = gtk_label_new("Interface");
  const char* interfaces[] = {"eth0", nullptr};
  auto* iface = gtk_drop_down_new_from_strings(interfaces);
  gtk_drop_down_set_selected(GTK_DROP_DOWN(iface), 0);
  auto* run = gtk_button_new_with_label("Run Qualification");
  gtk_widget_add_css_class(run, "suggested-action");
  gtk_box_append(GTK_BOX(controls), iface_label);
  gtk_box_append(GTK_BOX(controls), iface);
  gtk_box_append(GTK_BOX(controls), run);
  g_state.qual_iface = GTK_DROP_DOWN(iface);
  g_state.qual_run = GTK_BUTTON(run);

  auto* scrolled = gtk_scrolled_window_new();
  gtk_widget_set_vexpand(scrolled, TRUE);
  auto* view = gtk_text_view_new();
  gtk_text_view_set_editable(GTK_TEXT_VIEW(view), FALSE);
  gtk_text_view_set_monospace(GTK_TEXT_VIEW(view), TRUE);
  gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(view), GTK_WRAP_WORD_CHAR);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), view);
  g_state.qual_report = GTK_TEXT_VIEW(view);

  gtk_box_append(GTK_BOX(box), controls);
  gtk_box_append(GTK_BOX(box), scrolled);
  g_signal_connect(run, "clicked", G_CALLBACK(on_qual_run_clicked), nullptr);
  return box;
}

GtkWidget* build_packets_page() {
  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);

  auto* controls = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  auto* iface = gtk_entry_new();
  gtk_entry_set_placeholder_text(GTK_ENTRY(iface), "capture interface");
  gtk_widget_set_size_request(iface, 160, -1);
  auto* capture_start = gtk_button_new_with_label("Start Capture");
  auto* capture_stop = gtk_button_new_with_label("Stop Capture");
  auto* import_button = gtk_button_new_with_label("Import pcap");
  auto* export_button = gtk_button_new_with_label("Export pcap");
  auto* wireshark = gtk_button_new_with_label("Wireshark live");
  auto* clear = gtk_button_new_with_label("Clear");
  gtk_box_append(GTK_BOX(controls), iface);
  gtk_box_append(GTK_BOX(controls), capture_start);
  gtk_box_append(GTK_BOX(controls), capture_stop);
  gtk_box_append(GTK_BOX(controls), import_button);
  gtk_box_append(GTK_BOX(controls), export_button);
  gtk_box_append(GTK_BOX(controls), wireshark);
  gtk_box_append(GTK_BOX(controls), clear);
  g_state.capture_iface = GTK_ENTRY(iface);
  g_state.capture_start = GTK_BUTTON(capture_start);
  g_state.capture_stop = GTK_BUTTON(capture_stop);
  g_state.pcap_import = GTK_BUTTON(import_button);
  g_state.pcap_export = GTK_BUTTON(export_button);
  g_state.wireshark_live = GTK_BUTTON(wireshark);
  g_state.packets_clear = GTK_BUTTON(clear);

  auto* count = gtk_label_new("0 shown");
  gtk_label_set_xalign(GTK_LABEL(count), 0.0F);
  gtk_widget_add_css_class(count, "dim-label");
  g_state.packet_count = GTK_LABEL(count);

  auto* paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
  auto* list_scroller = gtk_scrolled_window_new();
  auto* list = gtk_list_box_new();
  gtk_list_box_set_selection_mode(GTK_LIST_BOX(list), GTK_SELECTION_SINGLE);
  gtk_widget_add_css_class(list, "monospace");
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(list_scroller), list);
  auto* detail_scroller = gtk_scrolled_window_new();
  auto* detail = gtk_text_view_new();
  gtk_text_view_set_editable(GTK_TEXT_VIEW(detail), FALSE);
  gtk_text_view_set_monospace(GTK_TEXT_VIEW(detail), TRUE);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(detail_scroller), detail);
  gtk_paned_set_start_child(GTK_PANED(paned), list_scroller);
  gtk_paned_set_end_child(GTK_PANED(paned), detail_scroller);
  gtk_widget_set_vexpand(paned, TRUE);
  g_state.packet_list = GTK_LIST_BOX(list);
  g_state.packet_detail = GTK_TEXT_VIEW(detail);

  gtk_box_append(GTK_BOX(box), controls);
  gtk_box_append(GTK_BOX(box), count);
  gtk_box_append(GTK_BOX(box), paned);

  g_signal_connect(capture_start, "clicked", G_CALLBACK(on_capture_start_clicked), nullptr);
  g_signal_connect(capture_stop, "clicked", G_CALLBACK(on_capture_stop_clicked), nullptr);
  g_signal_connect(clear, "clicked", G_CALLBACK(on_packets_clear_clicked), nullptr);
  g_signal_connect(import_button, "clicked", G_CALLBACK(on_pcap_import_clicked), nullptr);
  g_signal_connect(export_button, "clicked", G_CALLBACK(on_pcap_export_clicked), nullptr);
  g_signal_connect(wireshark, "clicked", G_CALLBACK(on_wireshark_clicked), nullptr);
  g_signal_connect(list, "row-selected", G_CALLBACK(on_packet_row_selected), nullptr);
  return box;
}

GtkWidget* build_logs_page() {
  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  auto* export_button = gtk_button_new_with_label("Export Logs");
  g_state.log_export = GTK_BUTTON(export_button);
  auto* scrolled = gtk_scrolled_window_new();
  gtk_widget_set_vexpand(scrolled, TRUE);
  auto* view = gtk_text_view_new();
  gtk_text_view_set_editable(GTK_TEXT_VIEW(view), FALSE);
  gtk_text_view_set_monospace(GTK_TEXT_VIEW(view), TRUE);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), view);
  g_state.log_view = GTK_TEXT_VIEW(view);
  gtk_box_append(GTK_BOX(box), export_button);
  gtk_box_append(GTK_BOX(box), scrolled);
  g_signal_connect(export_button, "clicked", G_CALLBACK(on_log_export_clicked), nullptr);
  return box;
}

GtkWidget* build_tuning_page() {
  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  auto* grid = gtk_grid_new();
  gtk_grid_set_row_homogeneous(GTK_GRID(grid), FALSE);
  gtk_grid_set_column_homogeneous(GTK_GRID(grid), FALSE);
  gtk_grid_set_row_spacing(GTK_GRID(grid), 8);
  gtk_grid_set_column_spacing(GTK_GRID(grid), 12);

  struct Field {
    char const* label;
    double min;
    double max;
    double value;
  };
  Field const fields[] = {
      {"clockClass", 0, 255, 6},          {"clockAccuracy", 0, 255, 254},
      {"offsetScaledLogVariance", 0, 65535, 65535},
      {"currentUtcOffset", -1000, 1000, 37},
      {"leap61", 0, 1, 0},                {"leap59", 0, 1, 0},
      {"utcOffsetValid", 0, 1, 1},        {"ptpTimescale", 0, 1, 1},
      {"timeTraceable", 0, 1, 0},         {"frequencyTraceable", 0, 1, 0},
      {"timeSource", 0, 255, 160},        {"priority1", 0, 255, 128},
      {"priority2", 0, 255, 128},
  };

  int row = 0;
  int column = 0;
  for (auto const& field : fields) {
    auto* label = gtk_label_new(field.label);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    auto* spin = gtk_spin_button_new_with_range(field.min, field.max, 1);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(spin), field.value);
    gtk_grid_attach(GTK_GRID(grid), label, column, row, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), spin, column + 1, row, 1, 1);
    g_state.gm_spin.emplace_back(field.label, GTK_SPIN_BUTTON(spin));
    row += 1;
    if (row >= 7) {
      row = 0;
      column += 2;
    }
  }

  auto* note = gtk_label_new("GM runtime tuning applies through pmc GRANDMASTER_SETTINGS_NP on the running engine (Pro).");
  gtk_label_set_wrap(GTK_LABEL(note), TRUE);
  gtk_widget_add_css_class(note, "dim-label");
  gtk_label_set_xalign(GTK_LABEL(note), 0.0F);

  auto* apply = gtk_button_new_with_label("Apply to Running Engine");
  gtk_widget_add_css_class(apply, "suggested-action");
  g_state.gm_apply = GTK_BUTTON(apply);

  gtk_box_append(GTK_BOX(box), grid);
  gtk_box_append(GTK_BOX(box), note);
  gtk_box_append(GTK_BOX(box), apply);
  g_signal_connect(apply, "clicked", G_CALLBACK(on_gm_apply_clicked), nullptr);
  return box;
}

GtkWidget* build_license_page() {
  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);

  auto* gate_row = info_row("License tier", &g_state.gate_value);

  auto* trial = gtk_button_new_with_label("Start Trial");
  auto* path = gtk_entry_new();
  gtk_entry_set_placeholder_text(GTK_ENTRY(path), "/path/to/license.lic");
  auto* activate = gtk_button_new_with_label("Activate License");
  auto* deactivate = gtk_button_new_with_label("Deactivate");
  auto* path_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  gtk_box_append(GTK_BOX(path_row), path);
  gtk_box_append(GTK_BOX(path_row), activate);
  gtk_box_append(GTK_BOX(path_row), deactivate);
  g_state.trial_start = GTK_BUTTON(trial);
  g_state.license_path = GTK_ENTRY(path);
  g_state.activate = GTK_BUTTON(activate);
  g_state.deactivate = GTK_BUTTON(deactivate);

  auto* exports = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  auto* report = gtk_button_new_with_label("Export Engineering Report");
  auto* diagnostics = gtk_button_new_with_label("Export Diagnostics");
  gtk_box_append(GTK_BOX(exports), report);
  gtk_box_append(GTK_BOX(exports), diagnostics);
  g_state.report_export = GTK_BUTTON(report);
  g_state.diagnostics_export = GTK_BUTTON(diagnostics);

  auto* note = gtk_label_new("Offline signed licenses; no cloud dependency. Real-engine roles and exports require Pro.");
  gtk_label_set_wrap(GTK_LABEL(note), TRUE);
  gtk_widget_add_css_class(note, "dim-label");
  gtk_label_set_xalign(GTK_LABEL(note), 0.0F);

  gtk_box_append(GTK_BOX(box), gate_row);
  gtk_box_append(GTK_BOX(box), trial);
  gtk_box_append(GTK_BOX(box), path_row);
  gtk_box_append(GTK_BOX(box), exports);
  gtk_box_append(GTK_BOX(box), note);

  g_signal_connect(trial, "clicked", G_CALLBACK(on_trial_clicked), nullptr);
  g_signal_connect(activate, "clicked", G_CALLBACK(on_activate_clicked), nullptr);
  g_signal_connect(deactivate, "clicked", G_CALLBACK(on_deactivate_clicked), nullptr);
  g_signal_connect(report, "clicked", G_CALLBACK(on_report_export_clicked), nullptr);
  g_signal_connect(diagnostics, "clicked", G_CALLBACK(on_diagnostics_export_clicked), nullptr);
  return box;
}

// ---- activation -----------------------------------------------------------

void on_activate(GtkApplication* app, gpointer) {
  if (g_state.window) {
    gtk_window_present(g_state.window);
    return;
  }
  (void)rivet::linux_ui::ApplyTheme();
  auto* window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(window), "gPTP Studio — Rivet + GTK4");
  gtk_window_set_default_size(GTK_WINDOW(window), 1080, 760);

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(root, 12);
  gtk_widget_set_margin_bottom(root, 12);
  gtk_widget_set_margin_start(root, 14);
  gtk_widget_set_margin_end(root, 14);

  auto* header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
  auto* title = gtk_label_new("gPTP Studio");
  gtk_widget_add_css_class(title, "title-2");
  auto* status = gtk_label_new("Starting embedded Racket CS…");
  gtk_label_set_xalign(GTK_LABEL(status), 0.0F);
  gtk_widget_add_css_class(status, "dim-label");
  gtk_widget_set_hexpand(status, TRUE);
  gtk_box_append(GTK_BOX(header), title);
  gtk_box_append(GTK_BOX(header), status);

  auto* stack = gtk_stack_new();
  gtk_stack_set_transition_type(GTK_STACK(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE);
  gtk_stack_add_titled(GTK_STACK(stack), build_engine_page(), "engine", "Engine");
  gtk_stack_add_titled(GTK_STACK(stack), build_qualification_page(), "qualification", "Qualification");
  gtk_stack_add_titled(GTK_STACK(stack), build_packets_page(), "packets", "Packets");
  gtk_stack_add_titled(GTK_STACK(stack), build_logs_page(), "logs", "Logs");
  gtk_stack_add_titled(GTK_STACK(stack), build_tuning_page(), "tuning", "GM Tuning");
  gtk_stack_add_titled(GTK_STACK(stack), build_license_page(), "license", "License & Reports");
  auto* switcher = gtk_stack_switcher_new();
  gtk_stack_switcher_set_stack(GTK_STACK_SWITCHER(switcher), GTK_STACK(stack));
  gtk_widget_set_vexpand(stack, TRUE);

  gtk_box_append(GTK_BOX(root), switcher);
  gtk_box_append(GTK_BOX(root), header);
  gtk_box_append(GTK_BOX(root), stack);
  gtk_window_set_child(GTK_WINDOW(window), root);

  g_state.window = GTK_WINDOW(window);
  g_state.stack = GTK_STACK(stack);
  g_state.status = GTK_LABEL(status);

  gtk_window_present(GTK_WINDOW(window));
  start_backend();
}

void on_shutdown(GApplication*, gpointer) {
  g_state.shutting_down.store(true, std::memory_order_release);
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }
  if (g_state.api) {
    g_state.backend->stop();
  }
}

}  // namespace

int main(int argc, char** argv) {
  auto app = gtk_application_new("site.jrtx.gptpstudio", G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
