# Zalo PC Scheduler for macOS

Tool này dùng `Accessibility API` của macOS để tự động thao tác trên `Zalo PC cá nhân`:

- Tìm người nhận theo tên trong ô search của Zalo
- Mở hội thoại
- Đính kèm ảnh bằng file picker của macOS
- Nhập nội dung chat
- Gửi theo lịch

## Yêu cầu

- `macOS`
- `Zalo.app` đã đăng nhập sẵn
- `Python 3`
- `Swift` có sẵn trên máy
- Đã cấp quyền `Accessibility` cho app/process đang chạy tool

Nếu lần đầu chạy bị báo thiếu quyền, vào:

- `System Settings > Privacy & Security > Accessibility`
- Nếu chạy bằng Terminal: bật quyền cho `Terminal` hoặc `iTerm`
- Nếu chạy bằng launcher: mở app, bấm `Kiểm tra` trong thẻ `Accessibility`, rồi bật `ZaloSchedulerLauncher`

## Cấu trúc file

- [main.py](/Users/mac/Documents/ZALOautoCHATPC/main.py)
- [zalo_helper.swift](/Users/mac/Documents/ZALOautoCHATPC/zalo_helper.swift)
- [config/jobs.example.json](/Users/mac/Documents/ZALOautoCHATPC/config/jobs.example.json)

## Build helper

```bash
python3 /Users/mac/Documents/ZALOautoCHATPC/main.py build-helper
```

## Build launcher app

```bash
python3 /Users/mac/Documents/ZALOautoCHATPC/build_launcher.py
open /Users/mac/Documents/ZALOautoCHATPC/dist/ZaloSchedulerLauncher.app
```

App launcher build ra tại:

- [dist/ZaloSchedulerLauncher.app](/Users/mac/Documents/ZALOautoCHATPC/dist/ZaloSchedulerLauncher.app)

Khi dùng app:

- config/log/state sẽ nằm trong `/Users/mac/Library/Application Support/ZaloSchedulerLauncher`
- app điều khiển Zalo là `ZaloSchedulerLauncher.app/Contents/MacOS/ZaloSchedulerLauncher`
- bấm `Yêu cầu quyền` trong thẻ `Accessibility` để macOS mở prompt quyền đúng lúc

## Kiểm tra Zalo có đang điều khiển được không

```bash
python3 /Users/mac/Documents/ZALOautoCHATPC/main.py probe
```

Nếu thành công, lệnh sẽ trả JSON có `searchField`, `messageInput`, `imageButton`.

## Mở thử chat mà không gửi

```bash
python3 /Users/mac/Documents/ZALOautoCHATPC/main.py open-chat \
  --recipient "Dũng Mập Địch"
```

Lệnh này chỉ mở đúng hội thoại và dừng lại, không gửi tin.

## Gửi thử ngay

```bash
python3 /Users/mac/Documents/ZALOautoCHATPC/main.py send-now \
  --recipient "Dũng Mập Địch" \
  --message "Test gửi từ scheduler" \
  --image "/Users/mac/Pictures/sample-1.jpg"
```

Lưu ý: lệnh này sẽ gửi thật.

## Chạy theo lịch

1. Sửa file [config/jobs.example.json](/Users/mac/Documents/ZALOautoCHATPC/config/jobs.example.json)
2. Chạy validate:

```bash
python3 /Users/mac/Documents/ZALOautoCHATPC/main.py validate-config \
  --config /Users/mac/Documents/ZALOautoCHATPC/config/jobs.example.json
```

3. Chạy scheduler:

```bash
python3 /Users/mac/Documents/ZALOautoCHATPC/main.py run \
  --config /Users/mac/Documents/ZALOautoCHATPC/config/jobs.example.json
```

Log sẽ ghi vào:

- [logs/scheduler.log](/Users/mac/Documents/ZALOautoCHATPC/logs/scheduler.log)

State chống gửi trùng sẽ lưu ở:

- [config/state.json](/Users/mac/Documents/ZALOautoCHATPC/config/state.json)

## Định dạng lịch

### Gửi 1 lần

```json
{
  "type": "once",
  "at": "2026-05-01T18:30:00+07:00"
}
```

### Gửi mỗi ngày

```json
{
  "type": "daily",
  "at": "08:15",
  "days": [0, 1, 2, 3, 4, 5, 6]
}
```

Quy ước `days`:

- `0`: Thứ 2
- `1`: Thứ 3
- `2`: Thứ 4
- `3`: Thứ 5
- `4`: Thứ 6
- `5`: Thứ 7
- `6`: Chủ nhật

## Giới hạn hiện tại

- Tool dựa trên UI hiện tại của Zalo PC; nếu Zalo đổi layout lớn thì có thể phải chỉnh helper.
- Tên người nhận nên đủ rõ để tránh trùng kết quả tìm kiếm.
- Ảnh được gửi từng file qua hộp thoại chọn ảnh của macOS.
- Khi gửi text, tool sẽ dùng clipboard để dán nội dung vào Zalo.
- Máy phải mở, Zalo phải đang đăng nhập, và scheduler phải đang chạy.
