TARGET = wayvibes

SRC = src/main.cpp src/audio.cpp src/device.cpp src/config.cpp src/analytics.cpp src/secure_file.cpp
INC = -Isrc
CXXFLAGS ?= -std=c++17 $(INC) -O2
LIBS = -levdev

all: $(TARGET)

$(TARGET): $(SRC) src/miniaudio.h
	$(CXX) $(CXXFLAGS) -o $(TARGET) $(SRC) $(LIBS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
