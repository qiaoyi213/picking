#include <libraw/libraw.h>
#include <iostream>
#include <string>

/*
    處理影像轉換的核心類別
    封裝 LibRaw 的資源管理與錯誤處理
 */

class RawProcessor {
public:
    RawProcessor() : processor_(new LibRaw()) {}
    ~RawProcessor() {
        processor_->recycle();
        delete processor_;
    }

    bool processFile(const std::string& inputPath, const std::string& outputPath) {
        // 1. 開啟並讀取檔案
        int status = processor_->open_file(inputPath.c_str());
        if (status != LIBRAW_SUCCESS) {
            std::cerr << "無法開啟檔案: " << LibRaw::strerror(status) << std::endl;
            return false;
        }

        // 2. 解開影像數據
        status = processor_->unpack();
        if (status != LIBRAW_SUCCESS) {
            std::cerr << "解碼失敗: " << LibRaw::strerror(status) << std::endl;
            return false;
        }

        ushort (*raw_pixels)[4] = processor_->imgdata.image;

        return true;
    }

private:
    LibRaw* processor_;
};

int main(int argc, char* argv[]) {
    if (argc < 3) {
        std::cout << "Usage: " << argv[0] << " <input_raw> <output_ppm>" << std::endl;
        return 1;
    }

    RawProcessor processor;
    if (processor.processFile(argv[1], argv[2])) {
        std::cout << "影像處理成功並儲存至: " << argv[2] << std::endl;
        return 0;
    }

    return 1;
}
