#include "subtitle_overlay.h"

#include <algorithm>

namespace {

constexpr wchar_t kClassName[] = L"AsmrShelfSubtitleOverlay";

int Scale(int value, int dpi) { return MulDiv(value, dpi, 96); }

HFONT CreateOverlayFont(int point_size, int dpi, int weight) {
  return CreateFontW(-Scale(point_size, dpi), 0, 0, 0, weight, FALSE, FALSE,
                     FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                     CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, VARIABLE_PITCH,
                     L"Microsoft YaHei UI");
}

SIZE MeasureText(HDC dc, const std::wstring& text, HFONT font, int max_width) {
  if (text.empty()) {
    return SIZE{0, 0};
  }
  HGDIOBJ old = SelectObject(dc, font);
  RECT rect{0, 0, max_width, 0};
  DrawTextW(dc, text.c_str(), -1, &rect,
            DT_CALCRECT | DT_WORDBREAK | DT_CENTER | DT_NOPREFIX);
  SelectObject(dc, old);
  return SIZE{rect.right - rect.left, rect.bottom - rect.top};
}

}  // namespace

SubtitleOverlay::~SubtitleOverlay() {
  if (window_ && IsWindow(window_)) {
    DestroyWindow(window_);
  }
}

bool SubtitleOverlay::Show(const std::wstring& current,
                           const std::wstring& next, bool locked) {
  if (current.empty() && next.empty()) {
    Hide();
    return false;
  }
  current_ = current;
  next_ = next;
  locked_ = locked;
  if (!EnsureWindow()) {
    return false;
  }
  ApplyLockedStyle();
  Layout();
  ShowWindow(window_, SW_SHOWNOACTIVATE);
  SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  InvalidateRect(window_, nullptr, FALSE);
  return true;
}

void SubtitleOverlay::Update(const std::wstring& current,
                             const std::wstring& next) {
  if (!window_ || !IsWindow(window_)) {
    Show(current, next, locked_);
    return;
  }
  current_ = current;
  next_ = next;
  if (!IsWindowVisible(window_)) {
    ShowWindow(window_, SW_SHOWNOACTIVATE);
  }
  Layout();
  InvalidateRect(window_, nullptr, FALSE);
}

void SubtitleOverlay::Hide() {
  if (window_ && IsWindow(window_)) {
    ShowWindow(window_, SW_HIDE);
  }
}

void SubtitleOverlay::SetLocked(bool locked) {
  locked_ = locked;
  ApplyLockedStyle();
}

bool SubtitleOverlay::visible() const {
  return window_ != nullptr && IsWindow(window_) != FALSE &&
         IsWindowVisible(window_) != FALSE;
}

bool SubtitleOverlay::EnsureWindow() {
  if (window_ && IsWindow(window_)) {
    return true;
  }

  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = &SubtitleOverlay::WindowProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.lpszClassName = kClassName;
  RegisterClassExW(&wc);

  window_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kClassName, L"AsmrShelf 字幕", WS_POPUP, 0, 0, 420, 96,
      nullptr, nullptr, GetModuleHandleW(nullptr), this);
  if (!window_) {
    return false;
  }
  SetLayeredWindowAttributes(window_, 0, 235, LWA_ALPHA);
  return true;
}

void SubtitleOverlay::ApplyLockedStyle() {
  if (!window_ || !IsWindow(window_)) {
    return;
  }
  LONG_PTR style = GetWindowLongPtrW(window_, GWL_EXSTYLE);
  if (locked_) {
    style |= WS_EX_TRANSPARENT | WS_EX_NOACTIVATE;
  } else {
    style &= ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
  }
  SetWindowLongPtrW(window_, GWL_EXSTYLE, style);
  SetWindowPos(window_, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
}

void SubtitleOverlay::Layout() {
  if (!window_ || !IsWindow(window_)) {
    return;
  }

  const int dpi = Dpi();
  const int padding_x = Scale(26, dpi);
  const int padding_y = Scale(14, dpi);

  RECT work{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  int max_window_width = (work.right - work.left) - Scale(80, dpi);
  max_window_width = std::max(max_window_width, Scale(280, dpi));
  const int max_text_width = std::max(Scale(220, dpi),
                                      std::min(Scale(820, dpi),
                                               max_window_width -
                                                   2 * padding_x));

  HDC dc = GetDC(window_);
  HFONT current_font = CreateOverlayFont(24, dpi, FW_SEMIBOLD);
  HFONT next_font = CreateOverlayFont(16, dpi, FW_NORMAL);
  const SIZE current_size =
      MeasureText(dc, current_, current_font, max_text_width);
  const SIZE next_size = MeasureText(dc, next_, next_font, max_text_width);
  ReleaseDC(window_, dc);
  DeleteObject(current_font);
  DeleteObject(next_font);

  int width = std::max(current_size.cx, next_size.cx) + 2 * padding_x;
  width = std::max(width, Scale(220, dpi));
  width = std::min(width, max_window_width);

  int height = 2 * padding_y + current_size.cy;
  if (!next_.empty()) {
    height += Scale(8, dpi) + next_size.cy;
  }
  height = std::max(height, Scale(68, dpi));

  RECT current_rect{};
  GetWindowRect(window_, &current_rect);
  int x;
  int y;
  if (user_position_) {
    x = current_rect.left;
    y = current_rect.top;
  } else {
    x = work.left + ((work.right - work.left) - width) / 2;
    y = work.bottom - height - Scale(64, dpi);
  }
  x = std::clamp(x, static_cast<int>(work.left) + Scale(8, dpi),
                 std::max(static_cast<int>(work.left) + Scale(8, dpi),
                          static_cast<int>(work.right) - width -
                              Scale(8, dpi)));
  y = std::clamp(y, static_cast<int>(work.top) + Scale(8, dpi),
                 std::max(static_cast<int>(work.top) + Scale(8, dpi),
                          static_cast<int>(work.bottom) - height -
                              Scale(8, dpi)));

  SetWindowPos(window_, HWND_TOPMOST, x, y, width, height,
               SWP_NOACTIVATE | SWP_NOOWNERZORDER);
  HRGN region = CreateRoundRectRgn(0, 0, width + 1, height + 1,
                                   Scale(18, dpi), Scale(18, dpi));
  SetWindowRgn(window_, region, TRUE);
}

void SubtitleOverlay::Paint(HDC dc) {
  RECT client{};
  GetClientRect(window_, &client);
  HBRUSH background = CreateSolidBrush(RGB(18, 18, 22));
  FillRect(dc, &client, background);
  DeleteObject(background);

  SetBkMode(dc, TRANSPARENT);
  const int dpi = Dpi();
  const int padding_x = Scale(26, dpi);
  const int padding_y = Scale(14, dpi);
  const int max_text_width = std::max(Scale(160, dpi),
                                      client.right - 2 * padding_x);

  HFONT current_font = CreateOverlayFont(24, dpi, FW_SEMIBOLD);
  HFONT next_font = CreateOverlayFont(16, dpi, FW_NORMAL);
  const SIZE current_size =
      MeasureText(dc, current_, current_font, max_text_width);
  const SIZE next_size = MeasureText(dc, next_, next_font, max_text_width);

  int top = padding_y;
  if (!current_.empty()) {
    HGDIOBJ old = SelectObject(dc, current_font);
    SetTextColor(dc, RGB(245, 245, 250));
    RECT rect{padding_x, top, client.right - padding_x, top + current_size.cy};
    DrawTextW(dc, current_.c_str(), -1, &rect,
              DT_CENTER | DT_WORDBREAK | DT_NOPREFIX);
    SelectObject(dc, old);
    top += current_size.cy;
  }
  if (!next_.empty()) {
    top += Scale(8, dpi);
    HGDIOBJ old = SelectObject(dc, next_font);
    SetTextColor(dc, RGB(190, 190, 202));
    RECT rect{padding_x, top, client.right - padding_x, top + next_size.cy};
    DrawTextW(dc, next_.c_str(), -1, &rect,
              DT_CENTER | DT_WORDBREAK | DT_NOPREFIX);
    SelectObject(dc, old);
  }

  DeleteObject(current_font);
  DeleteObject(next_font);
}

void SubtitleOverlay::ClampToWorkArea() {
  if (!window_ || !IsWindow(window_)) {
    return;
  }
  RECT work{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  RECT rect{};
  GetWindowRect(window_, &rect);
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  const int margin = Scale(8, Dpi());
  const int x = std::clamp(rect.left, static_cast<int>(work.left) + margin,
                           std::max(static_cast<int>(work.left) + margin,
                                    static_cast<int>(work.right) - width -
                                        margin));
  const int y = std::clamp(rect.top, static_cast<int>(work.top) + margin,
                           std::max(static_cast<int>(work.top) + margin,
                                    static_cast<int>(work.bottom) - height -
                                        margin));
  SetWindowPos(window_, HWND_TOPMOST, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOACTIVATE);
}

int SubtitleOverlay::Dpi() const {
  HDC dc = window_ ? GetDC(window_) : GetDC(nullptr);
  const int dpi = dc ? GetDeviceCaps(dc, LOGPIXELSY) : 96;
  if (dc) {
    ReleaseDC(window_, dc);
  }
  return dpi > 0 ? dpi : 96;
}

LRESULT CALLBACK SubtitleOverlay::WindowProc(HWND window, UINT message,
                                             WPARAM wparam, LPARAM lparam) {
  SubtitleOverlay* self = nullptr;
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    self = static_cast<SubtitleOverlay*>(create->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(self));
  } else {
    self = reinterpret_cast<SubtitleOverlay*>(
        GetWindowLongPtrW(window, GWLP_USERDATA));
  }
  if (self) {
    return self->HandleMessage(window, message, wparam, lparam);
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

LRESULT SubtitleOverlay::HandleMessage(HWND window, UINT message,
                                       WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_NCHITTEST:
      return locked_ ? HTTRANSPARENT : HTCLIENT;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(window, &paint);
      Paint(dc);
      EndPaint(window, &paint);
      return 0;
    }
    case WM_LBUTTONDOWN: {
      if (locked_) {
        return 0;
      }
      SetCapture(window);
      dragging_ = true;
      GetCursorPos(&drag_cursor_);
      GetWindowRect(window, &drag_rect_);
      return 0;
    }
    case WM_MOUSEMOVE: {
      if (!dragging_) {
        return 0;
      }
      POINT cursor{};
      GetCursorPos(&cursor);
      const int x = drag_rect_.left + (cursor.x - drag_cursor_.x);
      const int y = drag_rect_.top + (cursor.y - drag_cursor_.y);
      user_position_ = true;
      SetWindowPos(window, HWND_TOPMOST, x, y, 0, 0,
                   SWP_NOSIZE | SWP_NOACTIVATE);
      return 0;
    }
    case WM_LBUTTONUP: {
      if (!dragging_) {
        return 0;
      }
      dragging_ = false;
      ReleaseCapture();
      user_position_ = true;
      ClampToWorkArea();
      return 0;
    }
    case WM_CLOSE:
      ShowWindow(window, SW_HIDE);
      return 0;
    case WM_DESTROY:
      window_ = nullptr;
      return 0;
    case WM_DPICHANGED:
      Layout();
      return 0;
    default:
      break;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
