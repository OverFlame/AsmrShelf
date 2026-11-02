#ifndef RUNNER_SUBTITLE_OVERLAY_H_
#define RUNNER_SUBTITLE_OVERLAY_H_

#include <windows.h>

#include <string>

/// Always-on-top desktop lyric window.
///
/// A standalone WS_POPUP window (not a Flutter child) so it stays visible when
/// the main window is minimized or unfocused. Text is pushed from Dart; this
/// class does not touch the player.
class SubtitleOverlay {
 public:
  SubtitleOverlay() = default;
  ~SubtitleOverlay();

  SubtitleOverlay(const SubtitleOverlay&) = delete;
  SubtitleOverlay& operator=(const SubtitleOverlay&) = delete;

  bool Show(const std::wstring& current, const std::wstring& next,
            bool locked);
  void Update(const std::wstring& current, const std::wstring& next);
  void Hide();
  void SetLocked(bool locked);
  bool visible() const;

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message,
                                     WPARAM wparam, LPARAM lparam);

  LRESULT HandleMessage(HWND window, UINT message, WPARAM wparam,
                        LPARAM lparam);
  bool EnsureWindow();
  void ApplyLockedStyle();
  void Layout();
  void Paint(HDC dc);
  void ClampToWorkArea();
  int Dpi() const;

  HWND window_ = nullptr;
  std::wstring current_;
  std::wstring next_;
  bool locked_ = false;
  bool dragging_ = false;
  bool user_position_ = false;
  POINT drag_cursor_{};
  RECT drag_rect_{};
};

#endif  // RUNNER_SUBTITLE_OVERLAY_H_
