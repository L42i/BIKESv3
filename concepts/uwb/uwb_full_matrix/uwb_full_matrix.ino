#include <SPI.h>
#include "DW1000Ranging.h"


#include <WiFi.h>
#include <esp_now.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>


#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>




// =====================================================
// CHANGE THESE
// =====================================================


static const int NUM_NODES = 4;
static const int MAX_PAIRS = NUM_NODES * (NUM_NODES - 1) / 2;


// Node 0:
// #define NODE_ID 0
// #define MY_ADDR "7D:00:22:EA:82:60:3B:90"


// Node 1:
// #define NODE_ID 1
// #define MY_ADDR "7D:00:22:EA:82:60:3B:91"


// Node 2:
// #define NODE_ID 2
// #define MY_ADDR "7D:00:22:EA:82:60:3B:92"


// Node 3:
#define NODE_ID 3
#define MY_ADDR "7D:00:22:EA:82:60:3B:93"




// =====================================================
// ADDRESS BOOK
// =====================================================


const char *ALL_NODE_ADDRS[4] = {
 "7D:00:22:EA:82:60:3B:90",
 "7D:00:22:EA:82:60:3B:91",
 "7D:00:22:EA:82:60:3B:92",
 "7D:00:22:EA:82:60:3B:93"
};




// =====================================================
// PINS
// =====================================================


#define SPI_SCK   18
#define SPI_MISO  19
#define SPI_MOSI  23


#define UWB_RST   27
#define UWB_IRQ   34
#define UWB_SS    21


#define I2C_SDA   4
#define I2C_SCL   5




// =====================================================
// TIMING
// =====================================================


static const unsigned long OLED_UPDATE_MS    = 500;
static const unsigned long STATE_TIMEOUT_MS  = 1500;
static const unsigned long SYNC_BROADCAST_MS = 100;
static const int STATE_CHANGE_BURST_COUNT    = 2;




// =====================================================
// OLED
// =====================================================


Adafruit_SSD1306 display(128, 64, &Wire, -1);




// =====================================================
// CONTROL / DATA MESSAGES
// =====================================================


enum MsgType : uint8_t {
 MSG_STATE_CHANGE = 1,
 MSG_RANGE_REPORT = 2
};


struct StateChangePacket {
 uint8_t  msgType;
 uint8_t  fromNode;
 uint8_t  pairIndex;
 uint16_t epoch;
};


struct RangeReportPacket {
 uint8_t  msgType;
 uint8_t  fromNode;
 uint8_t  toNode;
 uint8_t  pairIndex;
 uint16_t epoch;
 float    rangeMeters;
};


uint8_t broadcastAddress[] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};




// =====================================================
// FreeRTOS QUEUES
// =====================================================


struct PendingState {
 uint8_t  pairIndex;
 uint16_t epoch;
};


struct PendingRange {
 uint8_t  fromNode;
 uint8_t  toNode;
 uint8_t  pairIndex;
 uint16_t epoch;
 float    rangeMeters;
};


QueueHandle_t stateChangeQueue;
QueueHandle_t rangeReportQueue;




// =====================================================
// STATE
// =====================================================


enum Role {
 ROLE_UNKNOWN,
 ROLE_IDLE,
 ROLE_TAG,
 ROLE_ANCHOR
};


Role currentRole = ROLE_UNKNOWN;


float distanceMatrix[4][4];


uint8_t pairA[MAX_PAIRS];
uint8_t pairB[MAX_PAIRS];
uint8_t pairCount = 0;


uint8_t  currentPairIndex = 0;
uint16_t epochCounter     = 0;
unsigned long stateStartMs      = 0;
unsigned long lastOLEDUpdate    = 0;
unsigned long lastSyncBroadcast = 0;
bool currentPairDone = false;
bool pendingAdvance  = false;


unsigned long cycleStartMs = 0;




// =====================================================
// FORWARD DECLARATIONS
// =====================================================


void newRange();
void newDevice(DW1000Device *device);
void inactiveDevice(DW1000Device *device);


void initDisplay();
void updateOLED();


void initEspNow();
void sendStateChange(uint8_t nextPairIndex, uint16_t nextEpoch);
void sendRangeReport(uint8_t fromNode, uint8_t toNode, uint8_t pairIndex, uint16_t epoch, float rangeMeters);
void onEspNowRecv(const esp_now_recv_info_t *recv_info, const uint8_t *incomingData, int len);


void startAsTagRole();
void startAsAnchorRole();
void enterIdleRole();
void updateRole();
void applyPairState(uint8_t newPairIndex, uint16_t newEpoch);
void advanceToNextPair();
void restartWholeAlgorithm();


void buildPairList();
uint8_t currentPairA();
uint8_t currentPairB();
bool isCurrentPair(int a, int b);


void markCurrentPairDone();


void resetDistanceMatrix();
void setDistanceSymmetric(int a, int b, float d);
void printRingDistances();


String formatDistance(float d);
String roleLabel();
String normalizeAddrString(const String &addr);
int nodeIndexFromLongAddress(const String &addr);
String deviceLongAddressToString(DW1000Device *device);




// =====================================================
// SETUP
// =====================================================


void setup() {
 Serial.begin(115200);
 delay(200);


 SPI.begin(SPI_SCK, SPI_MISO, SPI_MOSI);


 DW1000Ranging.initCommunication(UWB_RST, UWB_SS, UWB_IRQ);
 // DW1000.setAntennaDelay(16600);


 /*
 switch(NODE_ID) {
   case 1:
     DW1000.setAntennaDelay(16600);
     break;
   case 2:
     DW1000.setAntennaDelay(16600);
     break;
   case 3:
     DW1000.setAntennaDelay(15970);
     break;
   case 0:
     DW1000.setAntennaDelay(15970);
     break;
   default:
     break;
 }
 */


 DW1000Ranging.attachNewRange(newRange);
 DW1000Ranging.attachNewDevice(newDevice);
 DW1000Ranging.attachInactiveDevice(inactiveDevice);
 DW1000Ranging.useRangeFilter(false);


 stateChangeQueue = xQueueCreate(1, sizeof(PendingState));
 rangeReportQueue = xQueueCreate(8, sizeof(PendingRange));


 initDisplay();
 initEspNow();
 buildPairList();
 resetDistanceMatrix();


 cycleStartMs = millis();
 applyPairState(0, 0);
}




// =====================================================
// LOOP
// =====================================================


void loop() {
 if (currentRole == ROLE_TAG || currentRole == ROLE_ANCHOR) {
   DW1000Ranging.loop();
 }


 // Consume pending advance set by newRange()
 if (pendingAdvance && NODE_ID == currentPairA()) {
   pendingAdvance = false;
   advanceToNextPair();
 }


 // TAG periodically rebroadcasts current state so dropped nodes can resync
 if (NODE_ID == currentPairA() && millis() - lastSyncBroadcast >= SYNC_BROADCAST_MS) {
   sendStateChange(currentPairIndex, epochCounter);
   lastSyncBroadcast = millis();
 }


 // --- Process incoming state-change messages ---
 {
   PendingState ps;
   if (xQueueReceive(stateChangeQueue, &ps, 0) == pdTRUE) {
     if (ps.pairIndex != currentPairIndex || ps.epoch != epochCounter) {
       applyPairState(ps.pairIndex, ps.epoch);
     }
   }
 }


 // --- Process incoming range reports ---
 {
   PendingRange pr;
   while (xQueueReceive(rangeReportQueue, &pr, 0) == pdTRUE) {
     if (pr.epoch != epochCounter) continue;
     if (pr.pairIndex != currentPairIndex) continue;
     if (pr.fromNode >= NUM_NODES || pr.toNode >= NUM_NODES) continue;
     if (pr.rangeMeters < 0.0f) continue;


     setDistanceSymmetric(pr.fromNode, pr.toNode, pr.rangeMeters);


     if (NODE_ID == currentPairA() &&
         currentRole == ROLE_TAG &&
         isCurrentPair(pr.fromNode, pr.toNode) &&
         !currentPairDone) {


       markCurrentPairDone();
       pendingAdvance = true;
     }
   }
 }


 // --- Timeout: every node resets the whole network back to 0 ---
 if (millis() - stateStartMs >= STATE_TIMEOUT_MS) {
   Serial.print("bottleneck! pair: ");
   Serial.print(currentPairA() + 1);
   Serial.print("-");
   Serial.print(currentPairB() + 1);
   Serial.print(" epoch: ");
   Serial.println(epochCounter);


   pendingAdvance = false;
   sendStateChange(0, 0);
   restartWholeAlgorithm();
 }


 if (millis() - lastOLEDUpdate >= OLED_UPDATE_MS) {
   updateOLED();
   lastOLEDUpdate = millis();
 }
}




// =====================================================
// OLED
// =====================================================


void initDisplay() {
 Wire.begin(I2C_SDA, I2C_SCL);
 delay(50);


 if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
   for (;;) {}
 }


 display.clearDisplay();
 display.setTextColor(SSD1306_WHITE);
 display.display();
}


String formatDistance(float d) {
 if (d < 0.0f) return "---";
 return String(d, 2);
}


String roleLabel() {
 if (currentRole == ROLE_TAG)    return "TAG";
 if (currentRole == ROLE_ANCHOR) return "ANC";
 if (currentRole == ROLE_IDLE)   return "IDL";
 return "UNK";
}


void updateOLED() {
 display.clearDisplay();
 display.setTextColor(SSD1306_WHITE);


 unsigned long stateElapsedMs = millis() - stateStartMs;
 String tStr = String(stateElapsedMs) + "ms";


 int16_t  x1, y1;
 uint16_t w, h;
 display.getTextBounds(tStr, 0, 0, &x1, &y1, &w, &h);


 int rightX = 128 - w;
 if (rightX < 0) rightX = 0;


 display.setTextSize(2);
 display.setCursor(0, 0);
 display.print("N");
 display.print(NODE_ID + 1);
 display.print(" ");
 display.print(roleLabel());


 display.setTextSize(1);
 display.setCursor(rightX, 0);
 display.print(tStr);


 display.setCursor(0, 20);
 bool first = true;
 for (int i = 0; i < NUM_NODES; i++) {
   if (i == NODE_ID) continue;
   if (!first) display.print(" ");
   display.print(i + 1);
   display.print(":");
   display.print(formatDistance(distanceMatrix[NODE_ID][i]));
   first = false;
 }


 display.setCursor(0, 36);
 display.print("pair:");
 display.print(currentPairA() + 1);
 display.print("-");
 display.print(currentPairB() + 1);
 display.print(" ep:");
 display.print(epochCounter);


 display.setCursor(0, 52);
 display.print("done:");
 display.print(currentPairDone ? "Y" : "N");


 display.display();
}




// =====================================================
// ESP-NOW
// =====================================================


void initEspNow() {
 WiFi.mode(WIFI_STA);
 WiFi.disconnect();


 if (esp_now_init() != ESP_OK) {
   for (;;) {}
 }


 esp_now_register_recv_cb(onEspNowRecv);


 esp_now_peer_info_t peerInfo = {};
 memcpy(peerInfo.peer_addr, broadcastAddress, 6);
 peerInfo.channel = 0;
 peerInfo.encrypt = false;


 esp_now_add_peer(&peerInfo);
}


void sendStateChange(uint8_t nextPairIndex, uint16_t nextEpoch) {
 StateChangePacket pkt;
 pkt.msgType   = MSG_STATE_CHANGE;
 pkt.fromNode  = NODE_ID;
 pkt.pairIndex = nextPairIndex;
 pkt.epoch     = nextEpoch;


 for (int i = 0; i < STATE_CHANGE_BURST_COUNT; i++) {
   esp_now_send(broadcastAddress, (uint8_t *)&pkt, sizeof(pkt));
 }
}


void sendRangeReport(uint8_t fromNode, uint8_t toNode, uint8_t pairIndex, uint16_t epoch, float rangeMeters) {
 RangeReportPacket pkt;
 pkt.msgType     = MSG_RANGE_REPORT;
 pkt.fromNode    = fromNode;
 pkt.toNode      = toNode;
 pkt.pairIndex   = pairIndex;
 pkt.epoch       = epoch;
 pkt.rangeMeters = rangeMeters;


 esp_now_send(broadcastAddress, (uint8_t *)&pkt, sizeof(pkt));
}


// Runs in WiFi task context — only use queue calls, never touch shared state directly
void onEspNowRecv(const esp_now_recv_info_t *recv_info, const uint8_t *incomingData, int len) {
 if (len == sizeof(StateChangePacket)) {
   StateChangePacket pkt;
   memcpy(&pkt, incomingData, sizeof(pkt));


   if (pkt.msgType != MSG_STATE_CHANGE) return;
   if (pkt.pairIndex >= pairCount) return;
   if (pkt.fromNode == NODE_ID) return;


   PendingState ps = { pkt.pairIndex, pkt.epoch };
   xQueueOverwrite(stateChangeQueue, &ps);
   return;
 }


 if (len == sizeof(RangeReportPacket)) {
   RangeReportPacket pkt;
   memcpy(&pkt, incomingData, sizeof(pkt));


   if (pkt.msgType != MSG_RANGE_REPORT) return;
   if (pkt.fromNode >= NUM_NODES || pkt.toNode >= NUM_NODES) return;
   if (pkt.rangeMeters < 0.0f) return;


   PendingRange pr = { pkt.fromNode, pkt.toNode, pkt.pairIndex, pkt.epoch, pkt.rangeMeters };
   xQueueSendToBack(rangeReportQueue, &pr, 0);
   return;
 }
}




// =====================================================
// ROLE MANAGEMENT
// =====================================================


void startAsTagRole() {
 // DW1000.spiWakeup(); — chip never actually sleeps
 DW1000Ranging.startAsTag(MY_ADDR, DW1000.MODE_SHORTDATA_FAST_LOWPOWER);
 currentRole = ROLE_TAG;
}


void startAsAnchorRole() {
 // DW1000.spiWakeup(); — chip never actually sleeps
 DW1000Ranging.startAsAnchor(MY_ADDR, DW1000.MODE_SHORTDATA_FAST_LOWPOWER, false);
 currentRole = ROLE_ANCHOR;
}


void enterIdleRole() {
 DW1000.idle();
 currentRole = ROLE_IDLE;
}


void updateRole() {
 Role desiredRole;


 if (NODE_ID == currentPairA()) {
   desiredRole = ROLE_TAG;
 } else if (NODE_ID == currentPairB()) {
   desiredRole = ROLE_ANCHOR;
 } else {
   desiredRole = ROLE_IDLE;
 }


 if (desiredRole == currentRole) return;


 if (desiredRole == ROLE_TAG) {
   startAsTagRole();
 } else if (desiredRole == ROLE_ANCHOR) {
   startAsAnchorRole();
 } else {
   enterIdleRole();
 }
}


void applyPairState(uint8_t newPairIndex, uint16_t newEpoch) {
 currentPairIndex = newPairIndex;
 epochCounter     = newEpoch;
 currentPairDone  = false;
 pendingAdvance   = false;
 stateStartMs     = millis();


 updateRole();
}


void advanceToNextPair() {
 uint8_t nextPair = currentPairIndex + 1;


 if (nextPair >= pairCount) {
   sendStateChange(0, epochCounter + 1);
   applyPairState(0, epochCounter + 1);
   cycleStartMs = millis();
   return;
 }


 uint16_t nextEpoch = epochCounter + 1;


 sendStateChange(nextPair, nextEpoch);
 applyPairState(nextPair, nextEpoch);
}


void restartWholeAlgorithm() {
 // resetDistanceMatrix(); — keep last known distances on dropout
 currentRole = ROLE_UNKNOWN;
 cycleStartMs = millis();
 applyPairState(0, 0);
}




// =====================================================
// PAIR LIST
// =====================================================


void buildPairList() {
 pairCount = 0;


 // All 6 unique pairs, but ordered so the same node does not stay
 // TAG for multiple different anchors in a row.


 // 1 -> 2
 pairA[pairCount] = 0;
 pairB[pairCount] = 1;
 pairCount++;


 // 3 -> 4
 pairA[pairCount] = 2;
 pairB[pairCount] = 3;
 pairCount++;


 // 2 -> 3
 pairA[pairCount] = 1;
 pairB[pairCount] = 2;
 pairCount++;


 // 4 -> 1
 pairA[pairCount] = 3;
 pairB[pairCount] = 0;
 pairCount++;


 // 1 -> 3
 pairA[pairCount] = 0;
 pairB[pairCount] = 2;
 pairCount++;


 // 2 -> 4
 pairA[pairCount] = 1;
 pairB[pairCount] = 3;
 pairCount++;


 Serial.println("PAIR SCHEDULE:");
 for (int i = 0; i < pairCount; i++) {
   Serial.print(i);
   Serial.print(": ");
   Serial.print(pairA[i] + 1);
   Serial.print(" -> ");
   Serial.println(pairB[i] + 1);
 }
}








uint8_t currentPairA() {
 return pairA[currentPairIndex];
}


uint8_t currentPairB() {
 return pairB[currentPairIndex];
}


bool isCurrentPair(int a, int b) {
 return ((a == currentPairA() && b == currentPairB()) ||
         (a == currentPairB() && b == currentPairA()));
}


void markCurrentPairDone() {
 if (currentPairDone) return;


 currentPairDone = true;
 stateStartMs = millis();
}




// =====================================================
// DISTANCE MATRIX
// =====================================================


void resetDistanceMatrix() {
 for (int i = 0; i < 4; i++) {
   for (int j = 0; j < 4; j++) {
     distanceMatrix[i][j] = (i == j) ? 0.0f : -1.0f;
   }
 }
}


void setDistanceSymmetric(int a, int b, float d) {
 if (a < 0 || a >= NUM_NODES || b < 0 || b >= NUM_NODES) return;


 distanceMatrix[a][b] = d;
 distanceMatrix[b][a] = d;
}


void printRingDistances() {
 if (NUM_NODES < 2) return;


 Serial.println("distance between bikes");


 // Prints every scheduled pair using your same line style.
 // Since buildPairList() now includes all 6 pairs,
 // this prints 1->2, 1->3, 1->4, 2->3, 2->4, 3->4.
 for (int i = 0; i < pairCount; i++) {
   int a = pairA[i];
   int b = pairB[i];


   Serial.print(a + 1);
   Serial.print(" -> ");
   Serial.print(b + 1);
   Serial.print(": ");


   if (distanceMatrix[a][b] < 0.0f) {
     Serial.println("---");
   } else {
     Serial.println(distanceMatrix[a][b], 2);
   }
 }
}




// =====================================================
// ADDRESS MAPPING
// =====================================================


String normalizeAddrString(const String &addr) {
 String s = addr;
 s.toUpperCase();
 return s;
}


int nodeIndexFromLongAddress(const String &addr) {
 String n = normalizeAddrString(addr);


 for (int i = 0; i < NUM_NODES; i++) {
   if (normalizeAddrString(String(ALL_NODE_ADDRS[i])) == n) {
     return i;
   }
 }


 return -1;
}


String deviceLongAddressToString(DW1000Device *device) {
 uint8_t *a = device->getByteAddress();


 char buf[24];
 snprintf(buf, sizeof(buf),
          "%02X:%02X:%02X:%02X:%02X:%02X:%02X:%02X",
          a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);


 return String(buf);
}




// =====================================================
// CALLBACKS
// =====================================================


void newRange() {
 DW1000Device *dev = DW1000Ranging.getDistantDevice();
 if (!dev) return;


 if (currentRole == ROLE_IDLE) return;


 String longAddr   = deviceLongAddressToString(dev);
 int    remoteNode = nodeIndexFromLongAddress(longAddr);
 float  range      = dev->getRange();


 if (remoteNode < 0) return;
 if (range < 0.0f)   return;


 if (!isCurrentPair(NODE_ID, remoteNode)) return;


 setDistanceSymmetric(NODE_ID, remoteNode, range);


 printRingDistances();


 /*
 Serial.print("[");
 Serial.print(millis());
 Serial.print("ms] UWB ");
 Serial.print(NODE_ID + 1);
 Serial.print(" -> ");
 Serial.print(remoteNode + 1);
 Serial.print(": ");
 Serial.println(range, 2);
 */


 sendRangeReport(NODE_ID, remoteNode, currentPairIndex, epochCounter, range);


 if (!currentPairDone) {
   markCurrentPairDone();
   pendingAdvance = true;
 }
}


void newDevice(DW1000Device *device) {
}


void inactiveDevice(DW1000Device *device) {
}








