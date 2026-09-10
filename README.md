# AppleHome

แอป iPhone (SwiftUI, iOS 26) สำหรับเปิด–ปิดไฟจากที่ไหนก็ได้ และเปิดไฟให้อัตโนมัติเมื่อคุณเข้ามาในรัศมีบ้านที่ตั้งไว้

- **บ้าน 3D** (RealityKit): หมุนดูได้ ห้องที่เปิดไฟจะเรืองแสงผ่านหน้าต่าง แตะห้องเพื่อกรองรายการไฟ
- **Liquid Glass UI**: การ์ดไฟที่เรืองแสงตามความสว่าง ตัวปรับความสว่างแนวตั้ง มี haptics และ spring animation
- **ถึงบ้าน (Geofence)**: ตั้งตำแหน่งบ้านบนแผนที่ 3D เลือกรัศมี 100 ม.–2 กม. เลือกไฟ เลือกว่าออกจากบ้านแล้วจะให้ปิดไฟไหม และตั้งให้ทำงานเฉพาะหลังพระอาทิตย์ตกได้
- **ควบคุมได้ 3 ทาง**: API ของคุณเอง (REST), Apple Home (HomeKit) และไฟตัวอย่าง (Demo)
- **ภาษาไทย + อังกฤษ** ตามภาษาของเครื่อง

## เริ่มใช้งาน

1. เปิด `AppleHome.xcodeproj` ใน Xcode 26
2. Target **AppleHome › Signing & Capabilities** เลือก Team ของคุณ (HomeKit capability ถูกตั้งไว้แล้วใน `AppleHome/AppleHome.entitlements`)
3. Run บน iPhone จริงเพื่อใช้ตำแหน่งและ HomeKit ส่วน Simulator ใช้ทดสอบ UI, API และ geofence ได้

> ถ้า build ลงเครื่องจริงแล้ว signing ไม่ยอมรับ HomeKit entitlement (ขึ้นอยู่กับประเภทบัญชี Developer) ให้ลบ capability HomeKit ออก ส่วนที่ควบคุมผ่าน API และ geofence ยังใช้งานได้ครบ

## การทำงานของ "เปิดไฟเมื่อถึงบ้าน"

| ประเภทไฟ | ใครเป็นคนสั่ง | เงื่อนไข |
|---|---|---|
| API | ตัวแอปเอง: iOS ปลุกแอปขึ้นมาทำงานเบื้องหลังตอนเข้าเขต (CLMonitor) แล้วแอปยิง `PATCH /lights/{id}` | ต้องตั้งสิทธิ์ตำแหน่งเป็น **"ตลอดเวลา"** |
| Apple Home | Home Hub (Apple TV / HomePod) ผ่าน Location Automation ที่แอปสร้างให้ใน Apple Home | ต้องมี **Home Hub** เพราะ HomeKit ไม่ยอมให้แอปสั่งอุปกรณ์ขณะอยู่เบื้องหลัง |

ในหน้า "ถึงบ้าน" มีปุ่ม **จำลองถึงบ้าน / ออกจากบ้าน** ไว้ทดสอบว่าไฟดวงไหนตอบสนอง

## API ของคุณเอง

ดูสเปกทั้งหมดได้ใน [API.md](API.md) มีแค่ 2 endpoint:

```
GET   {base}/lights
PATCH {base}/lights/{id}   { "on": true, "brightness": 80 }
```

ทดสอบด้วย mock server:

```bash
python3 mock-server/server.py
```

แล้วใส่ Server URL เป็น `http://localhost:8787` (Simulator) หรือ `http://<IP ของ Mac>:8787` (iPhone ที่อยู่ Wi-Fi เดียวกัน)

## ทดสอบ geofence บน Simulator

```bash
xcrun simctl location booted set 13.80,100.57       # อยู่นอกเขต
xcrun simctl location booted set 13.7466,100.5393   # เดินเข้าเขตบ้าน → ไฟเปิด
```

## โครงสร้างโค้ด

```
AppleHome/
  Models/      Light, Settings, ActivityLog
  Services/    LightProvider (+Demo), APILightProvider, HomeKitManager, LocationService (CLMonitor + Sun)
  Stores/      AppModel (composition root), HomeStore, ArrivalController
  Views/       Home (3D house, cards, detail), Arrival, Settings, Components
  Theme/       สี ฟอนต์ และ animation กลาง
```
