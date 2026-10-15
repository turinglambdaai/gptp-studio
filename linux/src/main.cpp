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
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <functional>
#include <optional>
#include <string>
#include <thread>
#include <string_view>
#include <vector>

#include "GeneratedBackend.hpp"
#include "chart_area.hpp"
#include "theme.hpp"

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

namespace {

// ---- host strings -----------------------------------------------------------
// Compiled-in mirror of the shared table (app/i18n.rkt is the single
// source; taskly's linux host keeps the same compiled-in fallback). The
// language follows the backend's settings via bootstrap.

char const* g_language = "en";

struct TrEntry {
  char const* key;
  char const* zh;
  char const* en;
};

TrEntry const kStrings[] = {
    {"menu-check-updates", "检查更新…", "Check for Updates…"},
    {"menu-about", "关于", "About"},
    {"update-checking", "正在检查更新…", "Checking for updates…"},
    {"update-up-to-date", "当前已是最新版本", "You're up to date"},
    {"update-available-title", "发现新版本", "Update available"},
    {"update-available-body", "新版本 {0} 可用，是否立即下载？",
     "Version {0} is available. Download it now?"},
    {"update-download", "下载更新", "Download"},
    {"update-open-releases", "查看发布页", "Open Releases Page"},
    {"update-check-failed", "检查更新失败：{0}", "Update check failed: {0}"},
    {"update-downloading", "正在下载新版本…", "Downloading the new version…"},
    {"update-downloading-percent", "正在下载新版本… {0}%",
     "Downloading the new version… {0}%"},
    {"update-applying", "正在安装更新…", "Installing the update…"},
    {"update-downloaded-deb",
     "更新已下载。本副本由系统包管理器管理，可用以下命令升级（需要授权）：",
     "Update downloaded. This copy is managed by the system package "
     "manager — upgrade with (authorization required):"},
    {"update-downloaded-tarball",
     "更新已就绪，将原地替换当前安装目录；完成后重启 gPTP Studio 即可切换到新版本。",
     "The update is ready and will replace this install in place; restart "
     "gPTP Studio afterwards to switch to the new version."},
    {"update-install", "安装更新", "Install"},
    {"update-open-folder", "打开所在文件夹", "Open Folder"},
    {"update-install-failed", "安装失败：{0}", "Install failed: {0}"},
    {"update-applied", "更新已安装。重启 gPTP Studio 以使用新版本。",
     "Update installed. Restart gPTP Studio to switch to the new version."},
    {"update-restart", "重启应用", "Quit to Restart"},
    {"update-later", "稍后", "Later"},
    {"updates-disabled", "自动更新已被 --no-update-check 关闭。",
     "Updates are disabled (--no-update-check)."},
    {"about-title", "关于 gPTP Studio", "About gPTP Studio"},
    {"about-comments",
     "面向 Automotive Ethernet 的 gPTP / IEEE 802.1AS 专业调试工作台（Linux）。",
     "Professional gPTP / IEEE 802.1AS debugging workstation for Automotive "
     "Ethernet (Linux)."},
    {"about-license",
     "许可证：源码 Apache-2.0；官方分发版本适用商业条款（EULA）",
     "Dual-licensed: Apache-2.0 (source) / commercial terms (official "
     "distribution)"},
    {"about-copy-diagnostics", "复制诊断信息", "Copy Diagnostics"},
    {"about-copied", "诊断信息已复制到剪贴板，可粘贴到 issue。",
     "Diagnostics copied to the clipboard — paste them into your issue."},
    {"dialog-close", "关闭", "Close"},
};

std::string tr(char const* key) {
  for (auto const& entry : kStrings) {
    if (std::strcmp(entry.key, key) == 0) {
      return std::string(std::string_view(g_language) == "zh" ? entry.zh
                                                              : entry.en);
    }
  }
  return std::string(key);
}

std::string format_positional(std::string const& pattern,
                              std::string const& argument) {
  auto const position = pattern.find("{0}");
  if (position == std::string::npos) {
    return pattern;
  }
  return pattern.substr(0, position) + argument +
         pattern.substr(position + 3);
}

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
  std::string version;  // the backend's app-version (bootstrap)
  bool updates_disabled{false};  // --no-update-check

  void set_status(std::string const& text) {
    gtk_label_set_text(GTK_LABEL(status), text.c_str());
  }
};

AppState g_state;

// Online-update UI state (the flow lives further below; the bootstrap
// handler and shutdown path reference these, so they are declared early).
struct UpdateFlowState {
  guint auto_check_source{0};  // one-shot 3 s launch-check timer
  guint poll_source{0};        // 400 ms update_state poll
  GtkWindow* progress_dialog{nullptr};
  GtkProgressBar* progress_bar{nullptr};
  GtkLabel* progress_label{nullptr};
  bool check_in_flight{false};
  bool download_in_flight{false};
};

UpdateFlowState g_update;

// The two menu items' labels follow the backend language (bootstrap), so
// the host keeps the items and rewrites the labels once the language lands.
GMenuItem* g_menu_item_updates{nullptr};
GMenuItem* g_menu_item_about{nullptr};

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
gboolean on_update_auto_check(gpointer);

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
      g_state.version = value.version;
      if (value.language == "zh" || value.language == "en") {
        g_language = value.language == "zh" ? "zh" : "en";
      }
      if (g_menu_item_updates != nullptr) {
        g_menu_item_set_label(g_menu_item_updates,
                              tr("menu-check-updates").c_str());
      }
      if (g_menu_item_about != nullptr) {
        g_menu_item_set_label(g_menu_item_about, tr("menu-about").c_str());
      }
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
  // Silent launch check: 3 s after the backend is up, gated by the
  // host-owned 4-hour stamp (docs/update-contract.md).
  if (!g_state.updates_disabled) {
    g_update.auto_check_source =
        g_timeout_add(3000, on_update_auto_check, nullptr);
  }
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

// ---------------------------------------------------------------------------
// Online update flow (docs/update-contract.md; ported from the family
// pattern, taskly's update_flow). The backend verifies the signed feed and
// downloads the artifact; this host owns only the UI: one silent throttled
// launch check (stamp file, at most once per 4 hours), a menu entry that
// bypasses the throttle, a consent dialog, 400 ms update-state polling, and
// the install hand-off per shape (deb: package-manager command + optional
// pkexec apply; tarball: in-place swap + restart). Every dialog parents to
// the main window, and every body label is selectable — error text must
// leave the screen with the user.
// ---------------------------------------------------------------------------

// UPDATE.md contract: at most one silent attempt per 4 hours, unix epoch
// seconds in a host-owned stamp file (the backend has no settings RPC and
// stays stateless about the throttle).
constexpr long long kUpdateThrottleSeconds = 4 * 60 * 60;

char const* kReleasesUrl =
    "https://github.com/turinglambdaai/gptp-studio/releases/latest";
char const* kIssuesUrl = "https://github.com/turinglambdaai/gptp-studio/issues";
char const* kWebsiteUrl = "https://gptp-studio.jrtx.site";

std::string update_stamp_path() {
  return std::string(g_get_user_data_dir()) + "/gptp-studio/last-update-check";
}

long long read_update_stamp() {
  std::ifstream in(update_stamp_path());
  long long value = 0;
  if (in >> value) {
    return value;
  }
  return 0;  // missing or malformed counts as "never checked"
}

void write_update_stamp() {
  auto const path = update_stamp_path();
  auto const slash = path.find_last_of('/');
  if (slash != std::string::npos) {
    g_mkdir_with_parents(path.substr(0, slash).c_str(), 0755);
  }
  std::ofstream out(path, std::ios::trunc);
  out << static_cast<long long>(std::time(nullptr)) << "\n";
}

void stop_update_poll() {
  if (g_update.poll_source != 0) {
    g_source_remove(g_update.poll_source);
    g_update.poll_source = 0;
  }
}

void close_update_progress() {
  if (g_update.progress_dialog != nullptr) {
    gtk_window_destroy(g_update.progress_dialog);
    g_update.progress_dialog = nullptr;
    g_update.progress_bar = nullptr;
    g_update.progress_label = nullptr;
  }
}

int on_update_poll_tick(gpointer);

// Applying (pkexec or in-place swap) reuses the progress surface with the
// percent bar pulsing; the poll drives the terminal states.
void start_apply_progress() {
  if (g_state.api == nullptr) {
    return;
  }
  auto* dialog = gtk_dialog_new_with_buttons(
      tr("update-applying").c_str(), g_state.window,
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      tr("update-later").c_str(), GTK_RESPONSE_CANCEL, nullptr);
  auto* area = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  auto* content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(content, 12);
  gtk_widget_set_margin_bottom(content, 6);
  gtk_widget_set_margin_start(content, 12);
  gtk_widget_set_margin_end(content, 12);
  gtk_box_append(GTK_BOX(area), content);
  auto* bar = gtk_progress_bar_new();
  gtk_widget_set_size_request(bar, 300, -1);
  gtk_progress_bar_set_pulse_step(GTK_PROGRESS_BAR(bar), 0.08);
  gtk_box_append(GTK_BOX(content), bar);
  auto* label = gtk_label_new(tr("update-applying").c_str());
  gtk_box_append(GTK_BOX(content), label);

  // Detaching only closes the progress UI — the backend keeps applying;
  // the next poll cycle (or a manual check) shows the outcome.
  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, gint, gpointer) {
        stop_update_poll();
        g_update.progress_dialog = nullptr;
        g_update.progress_bar = nullptr;
        g_update.progress_label = nullptr;
        g_update.download_in_flight = false;
        gtk_window_destroy(GTK_WINDOW(dialog));
      }),
      nullptr);
  g_signal_connect(
      dialog, "destroy",
      G_CALLBACK(+[](GtkWidget*, gpointer) {
        g_update.progress_dialog = nullptr;
        g_update.progress_bar = nullptr;
        g_update.progress_label = nullptr;
        stop_update_poll();
      }),
      nullptr);
  gtk_window_present(GTK_WINDOW(dialog));
  g_update.progress_dialog = GTK_WINDOW(dialog);
  g_update.progress_bar = GTK_PROGRESS_BAR(bar);
  g_update.progress_label = GTK_LABEL(label);
  g_update.poll_source = g_timeout_add(400, on_update_poll_tick, nullptr);
}

// A plain message dialog whose body text is selectable (UPDATE.md: the
// error is copyable — a bug report starts from this string).
void show_update_message(std::string const& title, std::string const& body) {
  auto* dialog = gtk_dialog_new_with_buttons(
      title.c_str(), g_state.window,
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      tr("dialog-close").c_str(), GTK_RESPONSE_CLOSE, nullptr);
  auto* area = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  auto* text = gtk_label_new(body.c_str());
  gtk_label_set_wrap(GTK_LABEL(text), TRUE);
  gtk_label_set_selectable(GTK_LABEL(text), TRUE);
  gtk_label_set_max_width_chars(GTK_LABEL(text), 60);
  gtk_widget_set_margin_top(text, 12);
  gtk_widget_set_margin_bottom(text, 6);
  gtk_widget_set_margin_start(text, 12);
  gtk_widget_set_margin_end(text, 12);
  gtk_box_append(GTK_BOX(area), text);
  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, gint, gpointer) {
        gtk_window_destroy(GTK_WINDOW(dialog));
      }),
      nullptr);
  gtk_window_present(GTK_WINDOW(dialog));
}

void show_update_error(std::string const& message) {
  show_update_message("gPTP Studio",
                      format_positional(tr("update-check-failed"), message));
}

void open_parent_folder(std::string const& file_path) {
  auto const slash = file_path.find_last_of('/');
  if (slash == std::string::npos) {
    return;
  }
  std::string const dir = file_path.substr(0, slash);
  if (dir.empty()) {
    return;
  }
  GFile* folder = g_file_new_for_path(dir.c_str());
  gchar* uri = g_file_get_uri(folder);
  gtk_show_uri(g_state.window, uri, GDK_CURRENT_TIME);
  g_free(uri);
  g_object_unref(folder);
}

void start_update_download();

// Download finished and verified: hand the staged artifact to its install
// shape. deb keeps the file and shows the package-manager command (apply
// through pkexec with the operator's consent); tarball swaps in place.
void show_staged_handoff(std::string const& staged_path) {
  bool const deb = staged_path.size() >= 4 &&
                   staged_path.compare(staged_path.size() - 4, 4, ".deb") == 0;
  auto* dialog = gtk_dialog_new_with_buttons(
      tr("update-downloading").c_str(), g_state.window,
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      tr("dialog-close").c_str(), GTK_RESPONSE_CLOSE, nullptr);
  auto* area = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  auto* content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(content, 12);
  gtk_widget_set_margin_bottom(content, 6);
  gtk_widget_set_margin_start(content, 12);
  gtk_widget_set_margin_end(content, 12);
  gtk_box_append(GTK_BOX(area), content);

  auto* hint = gtk_label_new(
      tr(deb ? "update-downloaded-deb" : "update-downloaded-tarball").c_str());
  gtk_label_set_wrap(GTK_LABEL(hint), TRUE);
  gtk_label_set_selectable(GTK_LABEL(hint), TRUE);
  gtk_label_set_max_width_chars(GTK_LABEL(hint), 60);
  gtk_box_append(GTK_BOX(content), hint);

  auto* path_label = gtk_label_new(staged_path.c_str());
  gtk_label_set_selectable(GTK_LABEL(path_label), TRUE);
  gtk_label_set_wrap(GTK_LABEL(path_label), TRUE);
  gtk_widget_add_css_class(path_label, "monospace");
  gtk_box_append(GTK_BOX(content), path_label);

  auto* buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_widget_set_halign(buttons, GTK_ALIGN_END);
  gtk_box_append(GTK_BOX(content), buttons);

  if (deb && g_file_test("/usr/bin/pkexec", G_FILE_TEST_EXISTS)) {
    auto* install = gtk_button_new_with_label(tr("update-install").c_str());
    gtk_widget_add_css_class(install, "suggested-action");
    g_signal_connect(
        install, "clicked",
        G_CALLBACK(+[](GtkButton*, gpointer user_data) {
          auto* parent = GTK_WINDOW(user_data);
          gtk_window_destroy(parent);
          if (g_state.api == nullptr || g_update.download_in_flight) {
            return;
          }
          start_apply_progress();
          g_state.api->apply_update_async(
              [](rivet_app::Result<rivet_app::UpdateState> result) {
                if (result.error) {
                  return;  // the poll owns the outcome
                }
              });
        }),
        dialog);
    gtk_box_append(GTK_BOX(buttons), install);
  }

  auto* open = gtk_button_new_with_label(tr("update-open-folder").c_str());
  g_object_set_data_full(
      G_OBJECT(open), "update-open-path",
      new std::string(staged_path),
      +[](gpointer data) { delete static_cast<std::string*>(data); });
  g_signal_connect(
      open, "clicked",
      G_CALLBACK(+[](GtkButton* button, gpointer) {
        auto const* p = static_cast<std::string const*>(
            g_object_get_data(G_OBJECT(button), "update-open-path"));
        if (p != nullptr) {
          open_parent_folder(*p);
        }
      }),
      nullptr);
  gtk_box_append(GTK_BOX(buttons), open);

  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, gint, gpointer) {
        gtk_window_destroy(GTK_WINDOW(dialog));
      }),
      nullptr);
  gtk_window_present(GTK_WINDOW(dialog));
}

void show_applied_dialog() {
  auto* dialog = gtk_dialog_new_with_buttons(
      tr("update-available-title").c_str(), g_state.window,
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      tr("update-later").c_str(), GTK_RESPONSE_CANCEL,
      tr("update-restart").c_str(), GTK_RESPONSE_ACCEPT, nullptr);
  auto* area = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  auto* text = gtk_label_new(tr("update-applied").c_str());
  gtk_label_set_wrap(GTK_LABEL(text), TRUE);
  gtk_label_set_selectable(GTK_LABEL(text), TRUE);
  gtk_label_set_max_width_chars(GTK_LABEL(text), 60);
  gtk_widget_set_margin_top(text, 12);
  gtk_widget_set_margin_bottom(text, 6);
  gtk_widget_set_margin_start(text, 12);
  gtk_widget_set_margin_end(text, 12);
  gtk_box_append(GTK_BOX(area), text);
  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, gint response, gpointer) {
        gtk_window_destroy(GTK_WINDOW(dialog));
        if (response == GTK_RESPONSE_ACCEPT && g_state.window != nullptr) {
          // Closing the main window ends the default application and runs
          // the clean shutdown (backend stop + thread join).
          gtk_window_destroy(g_state.window);
        }
      }),
      nullptr);
  gtk_window_present(GTK_WINDOW(dialog));
}

int on_update_poll_tick(gpointer) {
  if (g_state.api == nullptr || g_update.progress_dialog == nullptr) {
    g_update.poll_source = 0;
    return G_SOURCE_REMOVE;
  }
  g_state.api->update_state_async(
      [](rivet_app::Result<rivet_app::UpdateState> result) {
        if (result.error) {
          return;  // keep polling through hiccups
        }
        auto const state = result.get();
        idle_deliver([state]() mutable {
          if (g_update.progress_dialog == nullptr) {
            return;  // detached UI
          }
          if (g_update.progress_bar != nullptr) {
            if (state.state == "downloading") {
              auto const percent =
                  std::clamp<std::int64_t>(state.percent, 0, 100);
              gtk_progress_bar_set_fraction(g_update.progress_bar,
                                            static_cast<double>(percent) /
                                                100.0);
              if (g_update.progress_label != nullptr) {
                gtk_label_set_text(
                    g_update.progress_label,
                    format_positional(tr("update-downloading-percent"),
                                      std::to_string(percent))
                        .c_str());
              }
            } else if (state.state == "applying") {
              gtk_progress_bar_pulse(g_update.progress_bar);
            }
          }
          if (state.state != "staged" && state.state != "applied" &&
              state.state != "failed") {
            return;
          }
          stop_update_poll();
          close_update_progress();
          g_update.download_in_flight = false;
          if (state.state == "failed") {
            show_update_message(
                "gPTP Studio",
                format_positional(tr("update-install-failed"),
                                  state.error.value_or("unknown failure")));
            return;
          }
          if (state.state == "applied") {
            show_applied_dialog();
            return;
          }
          show_staged_handoff(state.staged_path.value_or(""));
        });
      });
  return G_SOURCE_CONTINUE;
}

void start_update_download() {
  if (g_state.api == nullptr || g_update.download_in_flight) {
    return;
  }
  g_update.download_in_flight = true;

  auto* dialog = gtk_dialog_new_with_buttons(
      tr("update-downloading").c_str(), g_state.window,
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      tr("update-later").c_str(), GTK_RESPONSE_CANCEL, nullptr);
  auto* area = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  auto* content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(content, 12);
  gtk_widget_set_margin_bottom(content, 6);
  gtk_widget_set_margin_start(content, 12);
  gtk_widget_set_margin_end(content, 12);
  gtk_box_append(GTK_BOX(area), content);
  auto* bar = gtk_progress_bar_new();
  gtk_widget_set_size_request(bar, 300, -1);
  gtk_box_append(GTK_BOX(content), bar);
  auto* label = gtk_label_new(tr("update-downloading").c_str());
  gtk_box_append(GTK_BOX(content), label);

  // Canceling only detaches the progress UI — the backend keeps
  // downloading (family parity: there is no cancel RPC).
  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, gint, gpointer) {
        stop_update_poll();
        g_update.progress_dialog = nullptr;
        g_update.progress_bar = nullptr;
        g_update.progress_label = nullptr;
        g_update.download_in_flight = false;
        gtk_window_destroy(GTK_WINDOW(dialog));
      }),
      nullptr);
  // DESTROY_WITH_PARENT: if the main window goes away the dialog dies with
  // it — clear the raw pointers and the poll so no tick touches dead
  // widgets.
  g_signal_connect(
      dialog, "destroy",
      G_CALLBACK(+[](GtkWidget*, gpointer) {
        g_update.progress_dialog = nullptr;
        g_update.progress_bar = nullptr;
        g_update.progress_label = nullptr;
        stop_update_poll();
      }),
      nullptr);
  gtk_window_present(GTK_WINDOW(dialog));
  g_update.progress_dialog = GTK_WINDOW(dialog);
  g_update.progress_bar = GTK_PROGRESS_BAR(bar);
  g_update.progress_label = GTK_LABEL(label);
  g_update.poll_source = g_timeout_add(400, on_update_poll_tick, nullptr);

  g_state.api->start_download_async(
      [](rivet_app::Result<rivet_app::UpdateState> result) {
        if (!result.error) {
          return;  // the poll owns the rest
        }
        idle_deliver([] {
          if (g_update.progress_dialog == nullptr) {
            return;
          }
          // The download never started; stop staring at a 0% bar.
          stop_update_poll();
          close_update_progress();
          g_update.download_in_flight = false;
          show_update_error("the download could not be started");
        });
      });
}

void show_update_consent(rivet_app::UpdateCheck const& check) {
  std::string const version = check.available_version.value_or("?");
  auto* dialog = gtk_dialog_new_with_buttons(
      tr("update-available-title").c_str(), g_state.window,
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      tr("update-later").c_str(), GTK_RESPONSE_CANCEL,
      tr("update-download").c_str(), GTK_RESPONSE_ACCEPT, nullptr);
  auto* area = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  auto* content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(content, 12);
  gtk_widget_set_margin_bottom(content, 6);
  gtk_widget_set_margin_start(content, 12);
  gtk_widget_set_margin_end(content, 12);
  gtk_box_append(GTK_BOX(area), content);
  auto* text = gtk_label_new(
      format_positional(tr("update-available-body"), version).c_str());
  gtk_label_set_wrap(GTK_LABEL(text), TRUE);
  gtk_label_set_selectable(GTK_LABEL(text), TRUE);
  gtk_label_set_max_width_chars(GTK_LABEL(text), 60);
  gtk_box_append(GTK_BOX(content), text);
  auto* releases = gtk_link_button_new_with_label(kReleasesUrl,
                                                  tr("update-open-releases").c_str());
  gtk_widget_set_halign(releases, GTK_ALIGN_START);
  gtk_box_append(GTK_BOX(content), releases);
  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, gint response, gpointer) {
        bool const go = response == GTK_RESPONSE_ACCEPT;
        gtk_window_destroy(GTK_WINDOW(dialog));
        if (go) {
          start_update_download();
        }
      }),
      nullptr);
  gtk_window_present(GTK_WINDOW(dialog));
}

// Check for updates. `silent` keeps every outcome except an available
// update invisible (the launch auto-check — never nag); a manual check
// reports everything. Any settled check records the stamp, so the next
// launch's silent attempt stays inside the 4-hour throttle.
void check_for_updates(bool silent) {
  if (g_state.api == nullptr || g_update.check_in_flight) {
    return;
  }
  if (g_state.updates_disabled) {
    if (!silent) {
      show_update_message("gPTP Studio", tr("updates-disabled"));
    }
    return;
  }
  g_update.check_in_flight = true;
  if (!silent) {
    g_state.set_status(tr("update-checking"));
  }
  g_state.api->check_updates_async(
      [silent](rivet_app::Result<rivet_app::UpdateCheck> result) {
        idle_deliver([result = std::move(result), silent]() mutable {
          g_update.check_in_flight = false;
          if (result.error) {
            // Transport-level failure: the backend is going away, so do
            // not pretend a check happened.
            if (silent) {
              return;
            }
            show_update_error("backend unreachable");
            return;
          }
          // The check settled (any status): record the stamp so the next
          // launch's silent attempt stays inside the 4-hour throttle.
          write_update_stamp();
          auto const check = result.get();
          if (check.status == "available") {
            show_update_consent(check);
            return;
          }
          if (silent) {
            return;  // auto-check only speaks when there is news
          }
          if (check.status == "error") {
            show_update_error(check.message.value_or("unknown failure"));
            return;
          }
          g_state.set_status("gPTP Studio " + check.current_version);
          show_update_message("gPTP Studio", tr("update-up-to-date"));
        });
      });
}

// Silent launch check: once per process, 3 s after the backend is up,
// gated by the 4-hour throttle stamp. A failed stamp read counts as
// "never checked" — silent mode ignores errors by contract.
gboolean on_update_auto_check(gpointer) {
  g_update.auto_check_source = 0;
  if (g_state.api == nullptr ||
      g_state.shutting_down.load(std::memory_order_acquire)) {
    return G_SOURCE_REMOVE;
  }
  auto const now = static_cast<long long>(std::time(nullptr));
  if (now - read_update_stamp() < kUpdateThrottleSeconds) {
    return G_SOURCE_REMOVE;  // throttled
  }
  check_for_updates(/*silent=*/true);
  return G_SOURCE_REMOVE;
}

// ---------------------------------------------------------------------------
// About + diagnostics (the brainfuel pattern: one click puts a redacted
// support text on the clipboard, aligned with the issue template fields —
// version, distro, kernel, Racket runtime, license tier, NIC/PHC verdicts,
// recent log tail).
// ---------------------------------------------------------------------------

void copy_text_to_clipboard(std::string const& text) {
  GdkClipboard* clipboard =
      gdk_display_get_clipboard(gdk_display_get_default());
  if (clipboard != nullptr) {
    gdk_clipboard_set_text(clipboard, text.c_str());
  }
}

void on_copy_diagnostics_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) {
    return;
  }
  g_state.api->diagnostics_text_async(
      [](rivet_app::Result<std::string> result) {
        if (result.error) {
          return;
        }
        auto const text = result.get();
        idle_deliver([text] {
          copy_text_to_clipboard(text);
          g_state.set_status(tr("about-copied"));
        });
      });
}

void show_about_dialog() {
  auto* dialog = gtk_dialog_new_with_buttons(
      tr("about-title").c_str(), g_state.window,
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      tr("dialog-close").c_str(), GTK_RESPONSE_CLOSE, nullptr);
  auto* area = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  auto* content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_set_margin_top(content, 16);
  gtk_widget_set_margin_bottom(content, 6);
  gtk_widget_set_margin_start(content, 16);
  gtk_widget_set_margin_end(content, 16);
  gtk_box_append(GTK_BOX(area), content);

  std::string const version =
      !g_state.version.empty() ? g_state.version : rivet_app::kVersion;
  auto* name = gtk_label_new(nullptr);
  gtk_label_set_markup(
      GTK_LABEL(name),
      g_markup_printf_escaped("<span size=\"x-large\" weight=\"bold\">"
                              "gPTP Studio %s</span>",
                              version.c_str()));
  gtk_label_set_selectable(GTK_LABEL(name), FALSE);
  gtk_box_append(GTK_BOX(content), name);

  auto* comments = gtk_label_new(tr("about-comments").c_str());
  gtk_label_set_wrap(GTK_LABEL(comments), TRUE);
  gtk_label_set_selectable(GTK_LABEL(comments), TRUE);
  gtk_label_set_max_width_chars(GTK_LABEL(comments), 52);
  gtk_label_set_justify(GTK_LABEL(comments), GTK_JUSTIFY_CENTER);
  gtk_box_append(GTK_BOX(content), comments);

  auto* links = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
  gtk_widget_set_halign(links, GTK_ALIGN_CENTER);
  gtk_box_append(GTK_BOX(content), links);
  gtk_box_append(GTK_BOX(links),
                 gtk_link_button_new(kWebsiteUrl));
  gtk_box_append(GTK_BOX(links),
                 gtk_link_button_new_with_label(kIssuesUrl, "GitHub Issues"));

  auto* license = gtk_label_new(tr("about-license").c_str());
  gtk_label_set_wrap(GTK_LABEL(license), TRUE);
  gtk_label_set_selectable(GTK_LABEL(license), TRUE);
  gtk_label_set_max_width_chars(GTK_LABEL(license), 52);
  gtk_widget_add_css_class(license, "dim-label");
  gtk_box_append(GTK_BOX(content), license);

  auto* copy = gtk_button_new_with_label(tr("about-copy-diagnostics").c_str());
  g_signal_connect(copy, "clicked",
                   G_CALLBACK(on_copy_diagnostics_clicked), nullptr);
  gtk_box_append(GTK_BOX(content), copy);

  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, gint, gpointer) {
        gtk_window_destroy(GTK_WINDOW(dialog));
      }),
      nullptr);
  gtk_window_present(GTK_WINDOW(dialog));
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
  // The status line is the error surface (backend errors, RPC failures);
  // the text must be selectable so a bug report can start from it.
  gtk_label_set_selectable(GTK_LABEL(status), TRUE);
  gtk_box_append(GTK_BOX(header), title);
  gtk_box_append(GTK_BOX(header), status);

  // App menu (the host's single menu surface): update check + about.
  auto* menu = g_menu_new();
  g_menu_item_updates =
      g_menu_item_new(tr("menu-check-updates").c_str(), "app.check-updates");
  g_menu_item_about = g_menu_item_new(tr("menu-about").c_str(), "app.about");
  g_menu_append_item(menu, g_menu_item_updates);
  g_menu_append_item(menu, g_menu_item_about);
  auto* menu_button = gtk_menu_button_new();
  gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu_button),
                                "open-menu-symbolic");
  gtk_widget_set_tooltip_text(menu_button, "Menu");
  gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(menu_button),
                                 G_MENU_MODEL(menu));
  gtk_box_append(GTK_BOX(header), menu_button);

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

// Headless doctor mode: start the backend, pull the support report, print
// it, exit. The window never opens (the README's --doctor contract).
int run_doctor(bool json) {
  auto layout = discover_runtime_layout();
  if (!layout) {
    std::fprintf(stderr, "missing runtime/*.boot and res/core.zo next to the executable\n");
    return 4;
  }
  rivet::linux_runtime::RacketRuntimeConfig config;
  config.executable_path = executable_path().string();
  config.petite_boot = layout->petite_boot.string();
  config.scheme_boot = layout->scheme_boot.string();
  config.racket_boot = layout->racket_boot.string();
  config.backend_bundle = layout->core.string();
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;
  try {
    rivet::linux_runtime::Backend backend(std::move(config));
    backend.start();
    rivet_app::API api(backend);
    auto report = api.doctor_report().get();
    std::fputs(json ? report.json.c_str() : report.text.c_str(), stdout);
    std::fputc('\n', stdout);
    return 0;
  } catch (std::exception const& error) {
    std::fprintf(stderr, "doctor failed: %s\n", error.what());
    return 2;
  }
}

int main(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    std::string_view flag = argv[i];
    if (flag == "--doctor") {
      return run_doctor(false);
    }
    if (flag == "--doctor-json") {
      return run_doctor(true);
    }
    if (flag == "--version") {
      std::puts("gPTP Studio (Rivet host)");
      return 0;
    }
    if (flag == "--no-update-check") {
      // Air-gapped hosts: skip the silent check entirely; the menu entry
      // still answers, with the disabled notice.
      g_state.updates_disabled = true;
    }
  }
  auto app = gtk_application_new("site.jrtx.gptpstudio", G_APPLICATION_DEFAULT_FLAGS);
  auto* check_updates_action = g_simple_action_new("check-updates", nullptr);
  g_signal_connect(
      check_updates_action, "activate",
      G_CALLBACK(+[](GSimpleAction*, GVariant*, gpointer) {
        check_for_updates(/*silent=*/false);
      }),
      nullptr);
  g_action_map_add_action(G_ACTION_MAP(app),
                          G_ACTION(check_updates_action));
  g_object_unref(check_updates_action);
  auto* about_action = g_simple_action_new("about", nullptr);
  g_signal_connect(
      about_action, "activate",
      G_CALLBACK(+[](GSimpleAction*, GVariant*, gpointer) {
        show_about_dialog();
      }),
      nullptr);
  g_action_map_add_action(G_ACTION_MAP(app), G_ACTION(about_action));
  g_object_unref(about_action);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
