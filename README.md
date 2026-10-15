# AppleHome

แอป iPhone (SwiftUI, iOS 26) สำหรับเปิด–ปิดไฟจากที่ไหนก็ได้ และเปิดไฟให้อัตโนมัติเมื่อคุณเข้ามาในรัศมีบ้านที่ตั้งไว้

- **บ้าน 3D** (RealityKit): หมุนดูได้ ห้องที่เปิดไฟจะเรืองแสงผ่านหน้าต่าง แตะห้องเพื่อกรองรายการไฟ
- **Liquid Glass UI**: การ์ดไฟที่เรืองแสงตามความสว่าง ตัวปรับความสว่างแนวตั้ง มี haptics และ spring animation
- **ถึงบ้าน (Geofence)**: ตั้งตำแหน่งบ้านบนแผนที่ 3D เลือกรัศมี 100 ม.–2 กม. เลือกไฟ เลือกว่าออกจากบ้านแล้วจะให้ปิดไฟไหม และตั้งให้ทำงานเฉพาะหลังพระอาทิตย์ตกได้
- **ควบคุมได้ 3 ทาง**: API ของคุณเอง (REST), Apple Home (HomeKit) และไฟตัวอย่าง (Demo)
- **ภาษาไทย + อังกฤษ** ตามภาษาของเครื่อง
- **สั่งไฟโดยไม่ต้องเปิดแอป**: ปุ่มใน Control Center / หน้าล็อก, Widget บนหน้าโฮม, Siri และแอป Shortcuts

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

รองรับ 2 แบบ เลือกได้ที่ **ตั้งค่า › เซิร์ฟเวอร์ไฟ (API) › ประเภท**

**1. อุปกรณ์เปิด/ปิดตัวเดียว** (เช่น ESP32 ต่อรีเลย์) — ทดสอบกับอุปกรณ์จริงแล้วใช้งานได้

```
POST {base}/api/on       -> {"on": true}
POST {base}/api/off      -> {"on": false}
GET  {base}/api/status   -> {"on": true}
```

ใส่ที่อยู่เป็น `http://192.168.1.46` และ API key ซึ่งจะถูกส่งไปใน header ชื่อ `X-API-Key` (เปลี่ยนชื่อ header และพาธได้ในแอป)

**2. เซิร์ฟเวอร์ที่มีไฟหลายดวง** ปรับความสว่างได้

```
GET   {base}/lights
PATCH {base}/lights/{id}   { "on": true, "brightness": 80 }
```

ดูสเปกทั้งหมดได้ใน [API.md](API.md)

ทดสอบด้วย mock server:

```bash
python3 mock-server/server.py
```

แล้วใส่ Server URL เป็น `http://localhost:8787` (Simulator) หรือ `http://<IP ของ Mac>:8787` (iPhone ที่อยู่ Wi-Fi เดียวกัน)

## ปุ่มลัด Control Center, Widget, Siri และ Shortcuts

ใช้ได้กับไฟจาก **API ของคุณเอง** (ทั้ง 3 แบบ) เท่านั้น เพราะ HomeKit ไม่ยอมให้สั่งอุปกรณ์จาก extension หรือตอนแอปอยู่เบื้องหลัง ส่วนไฟ HomeKit ใช้ปุ่มของแอป Home ได้อยู่แล้ว

- **Control Center / หน้าล็อก / Action button**: เพิ่มปุ่ม "Light" ของ AppleHome แล้วแตะค้างเพื่อเลือกว่าจะให้คุมไฟดวงไหน ถ้าไม่เลือกจะใช้ดวงแรก
- **Widget**: ขนาดเล็กบนหน้าโฮม และแบบวงกลมบนหน้าล็อก มีปุ่มเปิด–ปิดในตัว
- **Siri / Shortcuts**: "เปิดไฟด้วย AppleHome" และ "ปิดไฟด้วย AppleHome" ใช้ได้ทันที และในแอป Shortcuts มี action "เปิดหรือปิดไฟ" ให้เลือกไฟทีละดวง

Widget ทำงานใน process แยกจากแอป จึงอ่านการตั้งค่าและ API key / รหัส MQTT ผ่าน **App Group** `group.Jitwisut.AppleHome` ซึ่งถูกตั้งไว้แล้วใน entitlements ของทั้งสอง target ตอน build ลงเครื่องจริง ให้ Xcode สร้าง App Group นี้ให้ในบัญชี Developer ถ้า signing ไม่ยอมรับ App Group ตัวแอปยังใช้งานได้ปกติ แต่ widget จะอ่านการตั้งค่าไม่ได้

> บน Simulator ปุ่ม "Lights On / Lights Off" ที่โชว์ในหน้า Shortcuts กดไม่ได้ ("Unable to run App Shortcut") เพราะ Simulator ไม่ได้ sign แอปด้วย Team ID แต่ action เดียวกันที่ใส่ไว้ใน shortcut ที่สร้างเองทำงานได้ปกติ

## ทดสอบ geofence บน Simulator

```bash
xcrun simctl location booted set 13.80,100.57       # อยู่นอกเขต
xcrun simctl location booted set 13.7466,100.5393   # เดินเข้าเขตบ้าน → ไฟเปิด
```

## โครงสร้างโค้ด

```
Shared/          ใช้ร่วมกันระหว่างแอปและ widget extension
  Light, Settings (+ AppGroup), LightProvider (+Demo), APILightProvider (+ Keychain)
  LightRemote    สั่งไฟจาก App Intent ได้โดยไม่ต้องพึ่ง AppModel + cache สถานะไฟให้ widget
  LightOptions   รายการไฟให้เลือกใน intent (ใช้ light id แบบ String แทน AppEntity)
  Theme          สี ฟอนต์ และ animation กลาง
AppleHome/
  Models/      ActivityLog
  Services/    HomeKitManager, LocationService (CLMonitor + Sun), ShortcutsService, NetworkMonitor
  Stores/      AppModel (composition root), HomeStore, ArrivalController
  Intents/     App Intents สำหรับ Siri / Shortcuts (เปิด/ปิดไฟ)
  Views/       Home (3D house, cards, detail), Arrival, Settings, Components
AppleHomeWidgets/  Control Center toggle, Widget และ intent ของมัน
```
