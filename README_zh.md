# Pic Kíng

Pic Kíng 是一款輕量的小工具，讓你可以快速瀏覽圖片並加上自訂標籤（tag），方便整理、分類與後續搜尋。  

---

## ✨ 功能特色

- 📂 **資料夾瀏覽**：直接載入資料夾，快速顯示所有圖片縮圖。  
- 🖼 **即時預覽**：點選縮圖即可切換大圖檢視。  
- 🏷 **標籤管理**：快速為圖片新增、刪除或編輯標籤。  
- 🎨 **縮圖高亮**：目前選擇的圖片會以外框標示，清楚辨識。  
- ⌨️ **快捷鍵支援**：透過鍵盤操作快速切換圖片與打標籤。  
- 💾 **資料儲存**：標籤結果可輸出成 JSON / CSV，方便後續整理或匯入其他工具。

---

## 🛠 安裝與建置

目前 Pic Kíng 採用 **C++17** + **ImGui** 實作，並支援 macOS。

### 環境需求
- macOS (建議 11 以上)
- CMake 3.15+
- C++17 編譯器 (clang++)
- [GLFW](https://www.glfw.org/)
- [stb_image.h](https://github.com/nothings/stb) (用於載入圖片)

### 建置流程
```bash
git clone https://github.com/yourusername/picking.git
cd picking
mkdir build && cd build
cmake ..
make
./build/main
```
