{ "model":"homeV2EthernetFeinstaub", "board": "senseBox:samd:sb"}
/*
  senseBox:home - Citizen Sensingplatform
  Version: ethernetv2_0.3
  Date: 2019-12-06
  Homepage: https://www.sensebox.de https://www.opensensemap.org
  Author: Reedu GmbH & Co. KG
  Note: Sketch for senseBox:home Ethernet MCU Edition with dust particle upgrade
  Model: homeEthernetV2Feinstaub
  Email: support@sensebox.de
  Code is in the public domain.
  https://github.com/sensebox/node-sketch-templater
*/

#include <Ethernet.h>
#include <Wire.h>
#include <senseBoxIO.h>
#include <SPI.h>

#include <Adafruit_Sensor.h>
#include <Adafruit_BMP280.h>
#include <Adafruit_HDC1000.h>
#include <Makerblog_TSL45315.h>
#include <VEML6070.h>
#include <SDS011-select-serial.h>
#include "bsec.h"


// Uncomment the next line to get debugging messages printed on the Serial port
// Do not leave this enabled for long time use
// #define ENABLE_DEBUG

#ifdef ENABLE_DEBUG
#define DEBUG(str) Serial.println(str)
#define DEBUG_ARGS(str,str1) Serial.println(str,str1)
#define DEBUG2(str) Serial.print(str)
#define DEBUG_WRITE(c) Serial.write(c)
#else
#define DEBUG(str)
#define DEBUG_ARGS(str,str1)
#define DEBUG2(str)
#define DEBUG_WRITE(c)
#endif

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

// Connected sensors
@@SENSORS|toDefineWithSuffixPrefixAndKey~,_CONNECTED,sensorType@@

// sensor IDs
@@SENSOR_IDS|toProgmem@@

byte mac[] = { 0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xED };
EthernetClient client;

//Configure static IP setup (only needed if DHCP is disabled)
IPAddress myIp(192, 168, 0, 42);
IPAddress myDns(8, 8, 8, 8);
IPAddress myGateway(192, 168, 0, 177);
IPAddress mySubnet(255, 255, 255, 0);

//Load sensors / instances
#ifdef HDC1080_CONNECTED
  Adafruit_HDC1000 HDC = Adafruit_HDC1000();
#endif
#ifdef BMP280_CONNECTED
  Adafruit_BMP280 BMP;
#endif
#ifdef TSL45315_CONNECTED
  Makerblog_TSL45315 TSL = Makerblog_TSL45315(TSL45315_TIME_M4);
#endif
#ifdef VEML6070_CONNECTED
  VEML6070 VEML;
#endif
#ifdef SDS011_CONNECTED
  SDS011 SDS(SDS_UART_PORT);
#endif
#ifdef SMT50_CONNECTED
  #define SOILTEMPPIN @@SOIL_DIGITAL_PORT|digitalPortToPortNumber@@
  #define SOILMOISPIN @@SOIL_DIGITAL_PORT|digitalPortToPortNumber~1@@
#endif
#ifdef SOUNDLEVELMETER_CONNECTED
  #define SOUNDMETERPIN @@SOUND_METER_PORT|digitalPortToPortNumber@@
#endif
#ifdef BME680_CONNECTED
  Bsec iaqSensor;
#endif

int dataLength;

typedef struct measurement {
  const char *sensorId;
  float value;
} measurement;

measurement measurements[NUM_SENSORS];
uint8_t num_measurements = 0;

// buffer for sprintf
char buffer[750];

/* ------------------------------------------------------------------------- */
/* --------------------------End of Configuration--------------------------- */
/* ------------------------------------------------------------------------- */

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
    DEBUG2(buffer);
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
    DEBUG(F("connecting..."));
    connected = client.connect(_server, 80);
    if (connected == true) {
      DEBUG(F("Connection successful, transferring..."));
      // construct the HTTP POST request:
      sprintf_P(buffer,
                PSTR("POST /boxes/%s/data HTTP/1.1\nHost: %s\nContent-Type: "
                     "text/csv\nConnection: close\nContent-Length: %i\n\n"),
                SENSEBOX_ID, server, dataLength);
      DEBUG2(buffer);

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
        if (client.available()) {
          break;
        }
      }
      delay(1000);
      while (client.available()) {
        char c = client.read();
        DEBUG_WRITE(c);
        // if the server's disconnected, stop the client:
        if (!client.connected()) {
          DEBUG();
          DEBUG("disconnecting from server.");
          client.stop();
          break;
        }
      }

      DEBUG("done!");

      // reset number of measurements
      num_measurements = 0;
      break;
    }
    delay(1000);
  }

  if (connected == false) {
    // Reset durchführen
    DEBUG(F("connection failed. Restarting..."));
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
  DEBUG("\nScanning...");
  for (int i = 0; i < sizeof(sensorAddr); i++) {
    Wire.beginTransmission(sensorAddr[i]);
    error = Wire.endTransmission();
    if (error == 0) {
      nDevices++;
      switch (sensorAddr[i])
      {
        case 0x29:
          DEBUG("TSL45315 found.");
          break;
        case 0x38: // &0x39
          DEBUG("VEML6070 found.");
          break;
        case 0x40:
          DEBUG("HDC1080 found.");
          break;
        case 0x76:
        #ifdef BMP280_CONNECTED
          DEBUG("BMP280 found.");
        #else
          DEBUG("BME680 found.");
        #endif
          break;
      }
    }
    else if (error == 4)
    {
      DEBUG2("Unknown error at address 0x");
      if (sensorAddr[i] < 16)
        DEBUG2("0");
      DEBUG_ARGS(sensorAddr[i], HEX);
    }
  }
  if (nDevices == 0) {
    DEBUG("No I2C devices found.\nCheck cable connections and press Reset.");
    while(true);
  } else {
    DEBUG2(nDevices);
    DEBUG(" sensors found.\n");
  }
}

void setup() {
  // Initialize serial and wait for port to open:
  #ifdef ENABLE_DEBUG
    Serial.begin(9600);
  #endif
  delay(5000);

  DEBUG2("xbee1 spi enable...");
  senseBoxIO.SPIselectXB1(); // select XBEE1 spi
  DEBUG("done");
  senseBoxIO.powerXB1(false);
  delay(200);
  DEBUG2("xbee1 power on...");
  senseBoxIO.powerXB1(true); // power ON XBEE1
  DEBUG("done");
  senseBoxIO.powerI2C(false);
  delay(200);
  senseBoxIO.powerI2C(true);

  Ethernet.init(23);
  // start the Ethernet connection:
  if (Ethernet.begin(mac) == 0) {
    DEBUG2("Failed to configure Ethernet using DHCP");
    // no point in carrying on, so do nothing forevermore:
    // try to congifure using IP address instead of DHCP:
    Ethernet.begin(mac, myIp);
  }
  // give the Ethernet shield a second to initialize:
  delay(1000);

  #ifdef ENABLE_DEBUG
    // init I2C/wire library
    Wire.begin();
    checkI2CSensors();
  #endif

  // Sensor initialization
  DEBUG(F("Initializing sensors..."));
  #ifdef HDC1080_CONNECTED
    HDC.begin();
  #endif
  #ifdef BMP280_CONNECTED
    BMP.begin(0x76);
  #endif
  #ifdef VEML6070_CONNECTED
    VEML.begin();
    delay(500);
  #endif
  #ifdef TSL45315_CONNECTED
    TSL.begin();
  #endif
  #ifdef BME680_CONNECTED
    iaqSensor.begin(BME680_I2C_ADDR_PRIMARY, Wire);
    checkIaqSensorStatus();
    bsec_virtual_sensor_t sensorList[10] = {
      BSEC_OUTPUT_RAW_TEMPERATURE,
      BSEC_OUTPUT_RAW_PRESSURE,
      BSEC_OUTPUT_RAW_HUMIDITY,
      BSEC_OUTPUT_RAW_GAS,
      BSEC_OUTPUT_IAQ,
      BSEC_OUTPUT_STATIC_IAQ,
      BSEC_OUTPUT_CO2_EQUIVALENT,
      BSEC_OUTPUT_BREATH_VOC_EQUIVALENT,
      BSEC_OUTPUT_SENSOR_HEAT_COMPENSATED_TEMPERATURE,
      BSEC_OUTPUT_SENSOR_HEAT_COMPENSATED_HUMIDITY,
    };
    iaqSensor.updateSubscription(sensorList, 10, BSEC_SAMPLE_RATE_LP);
    checkIaqSensorStatus();
  #endif
  #ifdef SDS011_CONNECTED
    SDS_UART_PORT.begin(9600);
  #endif
  DEBUG(F("Initializing sensors done!"));
  DEBUG(F("Starting loop in 3 seconds."));
  delay(3000);
}

void loop() {
  Serial.println(F("Loop"));
  // capture loop start timestamp
  unsigned long start = millis();
  dataLength = NUM_SENSORS - 1; // excluding linebreak after last measurement

  //-----Temperature-----//
  //-----Humidity-----//
  #ifdef HDC1080_CONNECTED
    addMeasurement(TEMPERSENSOR_ID, HDC.readTemperature());
    delay(200);
    addMeasurement(RELLUFSENSOR_ID, HDC.readHumidity());
  #endif

  //-----Pressure-----//
  #ifdef BMP280_CONNECTED
    float pressure;
    pressure = BMP.readPressure()/100;
    addMeasurement(LUFTDRSENSOR_ID, pressure);
  #endif

  //-----Lux-----//
  #ifdef TSL45315_CONNECTED
    addMeasurement(BELEUCSENSOR_ID, TSL.readLux());
  #endif

  //-----UV intensity-----//
  #ifdef VEML6070_CONNECTED
    addMeasurement(UVINTESENSOR_ID, VEML.getUV());
  #endif

  //-----PM-----//
  #ifdef SDS011_CONNECTED
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
  #endif

  //-----Soil Temperature & Moisture-----//
  #ifdef SMT50_CONNECTED
    float voltage = analogRead(SOILTEMPPIN) * (3.3 / 1024.0);
    float soilTemperature = (voltage - 0.5) * 100;
    addMeasurement(BODENTSENSOR_ID, soilTemperature);
    voltage = analogRead(SOILMOISPIN) * (3.3 / 1024.0);
    float soilMoisture = (voltage * 50) / 3;
    addMeasurement(BODENFSENSOR_ID, soilMoisture);
  #endif

  //-----dB(A) Sound Level-----//
  #ifdef SOUNDLEVELMETER_CONNECTED
    float v = analogRead(SOUNDMETERPIN) * (3.3 / 1024.0);
    float decibel = v * 50;
    addMeasurement(LAUTSTSENSOR_ID, decibel);
  #endif

  //-----BME680-----//
  #ifdef BME680_CONNECTED
    if (iaqSensor.run()) { // If new data is available
      addMeasurement(LUFTTESENSOR_ID, iaqSensor.temperature);
      addMeasurement(LUFTFESENSOR_ID, iaqSensor.humidity);
      addMeasurement(ATMLUFSENSOR_ID, iaqSensor.pressure / 100);
      addMeasurement(INNENRSENSOR_ID, iaqSensor.iaq);
      addMeasurement(CO2QUISENSOR_ID, iaqSensor.co2Equivalent);
      addMeasurement(ATEMLUSENSOR_ID, iaqSensor.breathVocEquivalent);
      addMeasurement(KALIBRSENSOR_ID, iaqSensor.iaqAccuracy);
    } else {
      checkIaqSensorStatus();
    }
  #endif

  DEBUG(F("submit values"));
  submitValues();

  // schedule next round of measurements
  for (;;) {
    unsigned long now = millis();
    unsigned long elapsed = now - start;
    if (elapsed >= postingInterval)
      return;
  }
}

#ifdef BME680_CONNECTED
// Helper function definitions
void checkIaqSensorStatus(void)
{
  if (iaqSensor.status != BSEC_OK) {
    if (iaqSensor.status < BSEC_OK) {
      String output = "BSEC error code : " + String(iaqSensor.status);
      Serial.println(output);
      for (;;)
        errLeds(); /* Halt in case of failure */
    } else {
      String output = "BSEC warning code : " + String(iaqSensor.status);
      Serial.println(output);
    }
  }

  if (iaqSensor.bme680Status != BME680_OK) {
    if (iaqSensor.bme680Status < BME680_OK) {
      String output = "BME680 error code : " + String(iaqSensor.bme680Status);
      Serial.println(output);
      for (;;)
        errLeds(); /* Halt in case of failure */
    } else {
      String output = "BME680 warning code : " + String(iaqSensor.bme680Status);
      Serial.println(output);
    }
  }
}

void errLeds(void)
{
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH);
  delay(100);
  digitalWrite(LED_BUILTIN, LOW);
  delay(100);
}
#endif