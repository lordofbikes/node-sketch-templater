{ "model":"homeV2EthernetFeinstaub", "board": "senseBox:samd:sb"}
/*
  senseBox:home - Citizen Sensingplatform
  Version: ethernetv2_0.1
  Date: 2018-05-17
  Homepage: https://www.sensebox.de https://www.opensensemap.org
  Author: Reedu GmbH & Co. KG
  Note: Sketch for senseBox:home Ethernet MCU Edition with dust particle upgrade
  Model: homeEthernetV2Feinstaub
  Email: support@sensebox.de
  Code is in the public domain.
  https://github.com/sensebox/node-sketch-templater
*/

#include <Ethernet2.h>

/* ------------------------------------------------------------------------- */
/* ------------------------------Configuration------------------------------ */
/* ------------------------------------------------------------------------- */

// Number of serial port the SDS011 is connected to. Either Serial1 or Serial2
#define SDS_UART_PORT (@@SERIAL_PORT@@) 

// Interval of measuring and submitting values in seconds
const unsigned int postingInterval = 60e3;

// address of the server to send to
const char server[] PROGMEM = "@@INGRESS_DOMAIN@@";

// senseBox ID
const char SENSEBOX_ID[] PROGMEM = "@@SENSEBOX_ID@@";

// Number of sensors
// Change this number if you add or remove sensors
// do not forget to remove or add the sensors on opensensemap.org
static const uint8_t NUM_SENSORS = @@NUM_SENSORS@@;

// sensor IDs
@@SENSOR_IDS|toProgmem@@

//Configure static IP setup (only needed if DHCP is disabled)
IPAddress myIp(192, 168, 0, 42);
IPAddress myDns(8, 8, 8, 8);
IPAddress myGateway(192, 168, 0, 177);
IPAddress mySubnet(255, 255, 255, 0);

/* ------------------------------------------------------------------------- */
/* --------------------------End of Configuration--------------------------- */
/* ------------------------------------------------------------------------- */

#include <senseBoxIO.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_BMP280.h>
#include <HDC100X.h>
#include <Makerblog_TSL45315.h>
#include <SDS011-select-serial.h>
#include <SPI.h>
#include <VEML6070.h>
#include <Wire.h>

byte mac[] = { 0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xED };
EthernetClient client;

// Sensor Instances
SDS011 SDS(SDS_UART_PORT);
Makerblog_TSL45315 TSL = Makerblog_TSL45315(TSL45315_TIME_M4);
HDC100X HDC(0x40);
Adafruit_BMP280 BMP;
VEML6070 VEML;

bool hdc, bmp, veml, tsl = false;
int dataLength;

typedef struct measurement {
  const char *sensorId;
  float value;
} measurement;

measurement measurements[NUM_SENSORS];
uint8_t num_measurements = 0;

// buffer for sprintf
char buffer[250];
char measurementsBuffer[NUM_SENSORS * 35];

void addMeasurement(const char *sensorId, float value) {
  measurements[num_measurements].sensorId = sensorId;
  measurements[num_measurements].value = value;
  num_measurements++;
  dataLength += String(sensorId).length() + 1; //length of ID + ','
  dataLength += String((int)value * 100).length() + 1; //length of measurement value + decimal digit
}

void writeMeasurementsToClient() {
  // iterate throug the measurements array 
  for (uint8_t i = 0; i < num_measurements; i++) 
  {
    //convert float to char[]
    float temp = measurements[i].value;
    int intPart = (int)measurements[i].value;
    temp -= intPart;
    temp *= 100; //2 decimal places
    int fracPart = (int)temp;
    sprintf_P(buffer, PSTR("%s,%i.%02i\n"), measurements[i].sensorId, intPart, fracPart);
    // transmit buffer to client
    client.print(buffer);
    Serial.print(buffer);
    //dataLength += String(buffer).length();
  }

  // reset num_measurements
  num_measurements = 0;
}

void submitValues() {
  // close any connection before send a new request.
  if (client.connected()) {
    client.stop();
    delay(1000);
  }
  bool connected = false;
  char _server[strlen_P(server)];
  strcpy_P(_server, server);
  for (uint8_t timeout = 2; timeout != 0; timeout--) {
    Serial.println(F("connecting..."));
    connected = client.connect(_server, 80);
    if (connected == true) {
      Serial.println(F("Connection successful, transferring..."));
      // construct the HTTP POST request:
      sprintf_P(buffer,
                PSTR("POST /boxes/%s/data HTTP/1.1\nHost: %s\nContent-Type: "
                     "text/csv\nConnection: close\nContent-Length: %i\n\n"),
                SENSEBOX_ID, server, dataLength);
      Serial.print(buffer);

      // send the HTTP POST request:
      client.print(buffer);

      // send measurements
      writeMeasurementsToClient();

      // send empty line to end the request
      client.println();

      uint16_t timeout = 0;
      // allow the response to be computed

      while (timeout <= 5000) {
        delay(10);
        timeout = timeout + 10;
        //                Serial.println(timeout);
        if (client.available()) {
          break;
        }
      }
      delay(1000);
      while (client.available()) {
        char c = client.read();
        Serial.write(c);
        // if the server's disconnected, stop the client:
        if (!client.connected()) {
          Serial.println();
          Serial.println("disconnecting from server.");
          client.stop();
          break;
        }
      }

      Serial.println("done!");

      // reset number of measurements
      num_measurements = 0;
      break;
    }
    delay(1000);
  }

  if (connected == false) {
    // Reset durchführen
    Serial.println(F("connection failed. Restarting..."));
    delay(5000);
    noInterrupts();
    NVIC_SystemReset();
    while (1)
      ;
  }
}

void checkI2CSensors() {
  byte error;
  int nDevices = 0;
  byte sensorAddr[] = {41, 56, 57, 64, 118};
  tsl = false; veml = false; hdc = false; bmp = false;
  Serial.println("\nScanning...");
  for (int i = 0; i < sizeof(sensorAddr); i++) {
    Wire.beginTransmission(sensorAddr[i]);
    error = Wire.endTransmission();
    if (error == 0) {
      nDevices++;
      switch (sensorAddr[i])
      {
        case 0x29:
          Serial.println("TSL45315 found.");
          tsl = true;
          break;
        case 0x38: // &0x39
          Serial.println("VEML6070 found.");
          veml = true;
          break;
        case 0x40:
          Serial.println("HDC1080 found.");
          hdc = true;
          break;
        case 0x76:
          Serial.println("BMP280 found.");
          bmp = true;
          break;
      }
    }
    else if (error == 4)
    {
      Serial.print("Unknown error at address 0x");
      if (sensorAddr[i] < 16)
        Serial.print("0");
      Serial.println(sensorAddr[i], HEX);
    }
  }
  if (nDevices == 0) {
    Serial.println("No I2C devices found.\nCheck cable connections and press Reset.");
    while(true);
  } else {
    Serial.print(nDevices);
    Serial.println(" sensors found.\n");
  }
  //return nDevices;
}

void setup() {
  // Initialize serial and wait for port to open:
  Serial.begin(9600);
  delay(5000);

  Serial.print("xbee1 spi enable...");
  senseBoxIO.SPIselectXB1(); // select XBEE1 spi
  Serial.println("done");
  senseBoxIO.powerXB1(false);delay(200);
  Serial.print("xbee1 power on...");
  senseBoxIO.powerXB1(true); // power ON XBEE1
  Serial.println("done");
  senseBoxIO.powerI2C(false);delay(200);
  senseBoxIO.powerI2C(true);

  Ethernet.init(23);
  // start the Ethernet connection:
  if (Ethernet.begin(mac) == 0) {
    Serial.println("Failed to configure Ethernet using DHCP");
    // no point in carrying on, so do nothing forevermore:
    // try to congifure using IP address instead of DHCP:
    Ethernet.begin(mac, myIp);
  }
  // give the Ethernet shield a second to initialize:
  delay(1000);
  // init I2C/wire library
  Wire.begin();
  // Sensor initialization
  Serial.println(F("Initializing sensors..."));
  SDS_UART_PORT.begin(9600);
  checkI2CSensors();
  if (veml) 
  {
    VEML.begin();
  }
  if (hdc)
  {
    HDC.begin(HDC100X_TEMP_HUMI, HDC100X_14BIT, HDC100X_14BIT, DISABLE);
    HDC.getTemp();
  }
  if (tsl)
    TSL.begin();
  if (bmp)
    BMP.begin(0x76);
  Serial.println(F("done!\n"));
  Serial.println(F("Starting loop in 3 seconds."));
  delay(3000);
}

void loop() {
  Serial.println(F("Loop"));
  // capture loop start timestamp
  unsigned long start = millis();
  dataLength = NUM_SENSORS - 1; // excluding linebreak after last measurement

  // read measurements from sensors
  if(hdc)
  {
    float temp = HDC.getTemp();
    addMeasurement(TEMPERSENSOR_ID, temp);
    delay(200);
    float humi = HDC.getHumi();
    addMeasurement(RELLUFSENSOR_ID, humi);
  }
  if(bmp)
  {
    float tempBaro, pressure, altitude;
    tempBaro = BMP.readTemperature();
    pressure = BMP.readPressure()/100;
    altitude = BMP.readAltitude(1013.25); //1013.25 = sea level pressure
    addMeasurement(LUFTDRSENSOR_ID, pressure);
  }
  if (tsl)
  {
    uint32_t lux = TSL.readLux();
    addMeasurement(BELEUCSENSOR_ID, lux);
  }
  if (veml)
  {
    float uv = VEML.getUV();
    addMeasurement(UVINTESENSOR_ID, uv);
  }
  uint8_t attempt = 0;
  float pm10, pm25;
  while (attempt < 5) {
    bool error = SDS.read(&pm25, &pm10);
    if (!error) {
      addMeasurement(PM10SENSOR_ID, pm10);
      addMeasurement(PM25SENSOR_ID, pm25);
      break;
    }
    attempt++;
  }
  
  Serial.println(F("submit values"));
  submitValues();
  // schedule next round of measurements
  for (;;) {
    unsigned long now = millis();
    unsigned long elapsed = now - start;
    if (elapsed >= postingInterval)
      return;
  }
}