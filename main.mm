#include "imgui.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_metal.h"

#include <libexif/exif-data.h>

#include <stdio.h>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <vector>
#include <string>
#include <fstream>
#include <iostream>
#include <map>
#define GLFW_INCLUDE_NONE
#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3.h>
#include <GLFW/glfw3native.h>

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <sys/types.h>
#include <sys/xattr.h>

const std::string FINDER_INFO_TAG = "com.apple.FinderInfo";



// 簡單的圖片包裝
struct ImageItem {
    std::string path;
    bool isLoaded;
    id<MTLTexture> thumbnail;
    id<MTLTexture> texture;
    bool exifLoaded;
    std::vector<std::pair<std::string, std::string>> exifEntries;
};

static std::vector<ImageItem> g_images;
static std::map<ImGuiKey, std::string> keyTagMappings;
static int g_currentIndex = 0;

id<MTLTexture> LoadExifThumbnailAsTexture(std::string path, id<MTLDevice> device) {
    // Step 1: 讀取 Exif
    ExifData *exifData = exif_data_new_from_file(path.c_str());
    if (!exifData) {
        NSLog(@"No EXIF data found in file: %s", path.c_str());
        return nil;
    }

    if (exifData->size <= 0 || !exifData->data) {
        NSLog(@"No EXIF thumbnail found in file: %s", path.c_str());
        exif_data_unref(exifData);
        return nil;
    }

    // Step 2: 把 Exif thumbnail 轉 NSData
    NSData *thumbData = [NSData dataWithBytes:exifData->data length:exifData->size];
    exif_data_unref(exifData);

    // Step 3: 用 NSData 生成 NSImage
    NSImage *nsImage = [[NSImage alloc] initWithData:thumbData];
    if (!nsImage) {
        NSLog(@"Failed to create NSImage from thumbnail data.");
        return nil;
    }

    // Step 4: 轉 CGImage
    CGImageRef cgRef = [nsImage CGImageForProposedRect:NULL context:NULL hints:nil];
    if (!cgRef) {
        NSLog(@"Failed to get CGImage from NSImage.");
        return nil;
    }

    size_t width  = CGImageGetWidth(cgRef);
    size_t height = CGImageGetHeight(cgRef);

    // Step 5: 建立 Metal Texture
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:(NSUInteger)width
                                                                                   height:(NSUInteger)height
                                                                                mipmapped:NO];
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    if (!texture) {
        NSLog(@"Failed to create Metal texture.");
        return nil;
    }

    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width*4,
                                                 CGColorSpaceCreateDeviceRGB(),
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!context) {
        NSLog(@"Failed to create CGContext.");
        return nil;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgRef);
    void *data = CGBitmapContextGetData(context);

    MTLRegion region = {{0,0,0}, { (NSUInteger)width, (NSUInteger)height, 1 }};
    [texture replaceRegion:region mipmapLevel:0 withBytes:data bytesPerRow:width*4];

    CGContextRelease(context);

    return texture;
}

// 載入 JPG 成 Metal Texture (這裡要用 CoreGraphics/UIImage)
id<MTLTexture> LoadTextureFromFile(id<MTLDevice> device, const std::string& filename) {
    NSImage* nsImage = [[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:filename.c_str()]];
    if (!nsImage) return nil;

    CGImageRef cgRef = [nsImage CGImageForProposedRect:NULL context:NULL hints:nil];
    if (!cgRef) return nil;

    size_t width  = CGImageGetWidth(cgRef);
    size_t height = CGImageGetHeight(cgRef);

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:(NSUInteger)width
                                                                                   height:(NSUInteger)height
                                                                                mipmapped:NO];
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];

    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width*4, CGColorSpaceCreateDeviceRGB(),
                                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(context, CGRectMake(0,0,width,height), cgRef);
    void* data = CGBitmapContextGetData(context);

    MTLRegion region = {{0,0,0}, { (NSUInteger)width, (NSUInteger)height, 1 }};
    [texture replaceRegion:region mipmapLevel:0 withBytes:data bytesPerRow:width*4];

    CGContextRelease(context);
    return texture;
}


// 掃描資料夾
void LoadAllImages(id<MTLDevice> device, const std::string& folder) {
    g_images.clear();
    g_currentIndex = 0;
    if (folder.empty() || !std::filesystem::exists(folder)) {
        return;
    }

    for (auto& entry : std::filesystem::directory_iterator(folder)) {
        if (entry.is_regular_file()) {
            auto ext = entry.path().extension().string();
            std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
            if (ext == ".jpg" || ext == ".jpeg") {
                ImageItem item;
                item.path = entry.path().string();
                item.isLoaded = false;
                item.thumbnail = LoadExifThumbnailAsTexture(item.path, device);
                item.texture = nil;
                item.exifLoaded = false;
                g_images.push_back(item);
            }
        }
    }
}

static void glfw_error_callback(int error, const char* description)
{
    fprintf(stderr, "Glfw Error %d: %s\n", error, description);
}
NSArray<NSString *> *GetFileTags(NSString *path) {
    const char *filePath = [path fileSystemRepresentation];
    const char *attrName = "com.apple.metadata:_kMDItemUserTags";

    // Step 1: 先問需要多少 buffer
    ssize_t size = getxattr(filePath, attrName, NULL, 0, 0, 0);
    if (size <= 0) {
        return nil; // 沒有標籤或錯誤
    }

    // Step 2: 配置 buffer
    void *buffer = malloc(size);
    if (!buffer) return nil;

    ssize_t result = getxattr(filePath, attrName, buffer, size, 0, 0);
    if (result < 0) {
        free(buffer);
        return nil;
    }

    // Step 3: 將 binary plist 轉成 NSArray
    NSData *data = [NSData dataWithBytes:buffer length:size];
    free(buffer);

    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:nil
                                                           error:&error];
    if (error || ![plist isKindOfClass:[NSArray class]]) {
        return nil;
    }

    return (NSArray<NSString *> *)plist;
}
bool SetFinderTags(const std::string& path, const std::vector<std::string>& tags) {
    @autoreleasepool {
        NSMutableArray *nsTags = [NSMutableArray array];
        for (auto &tag : tags) {
            [nsTags addObject:[NSString stringWithUTF8String:tag.c_str()]];
        }
        
        NSError *error = nil;
        NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:nsTags
                                                                       format:NSPropertyListBinaryFormat_v1_0
                                                                      options:0
                                                                        error:&error];
        if (!plistData) {
            std::cerr << "Error serializing plist: " << [[error localizedDescription] UTF8String] << "\n";
            return false;
        }
        
        int res = setxattr(path.c_str(),
                           "com.apple.metadata:_kMDItemUserTags",
                           [plistData bytes],
                           [plistData length],
                           0,
                           0);
        
        if (res != 0) {
            perror("setxattr failed");
            return false;
        }
    }
    return true;
}

std::string browse_folder() {
    std::string path = "";
    @autoreleasepool {
        // 初始化 App
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp activateIgnoringOtherApps:YES];

        // 建立一個 NSOpenPanel
        NSOpenPanel* panel = [NSOpenPanel openPanel];
        [panel setCanChooseFiles:NO];           // 不允許選檔案
        [panel setCanChooseDirectories:YES];    // 允許選資料夾
        [panel setAllowsMultipleSelection:NO];  // 只選一個資料夾
        [panel setPrompt:@"選擇"];
        
        // 顯示對話框
        if ([panel runModal] == NSModalResponseOK) {
            NSURL* url = [[panel URLs] firstObject];
            if (url) {
                printf("選到的資料夾: %s\n", [url fileSystemRepresentation]);
                path = [url fileSystemRepresentation];
            }
        } else {
            printf("使用者取消選擇\n");
        }
    }
    return path;
}

bool img_path_cmp(ImageItem i1, ImageItem i2) {
    return i1.path < i2.path;
}

static ImageItem* GetCurrentImage() {
    if (g_images.empty()) return nullptr;
    g_currentIndex = std::clamp(g_currentIndex, 0, (int)g_images.size() - 1);
    return &g_images[g_currentIndex];
}

static std::string GetFileName(const std::string& path) {
    return std::filesystem::path(path).filename().string();
}

static std::vector<std::string> GetFileTagsStd(const std::string& path) {
    NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
    NSArray<NSString *>* tags = GetFileTags(nsPath);
    if (!tags) {
        return {};
    }

    std::vector<std::string> out;
    out.reserve([tags count]);
    for (NSString* tag in tags) {
        out.emplace_back([tag UTF8String]);
    }
    return out;
}

static bool AddFinderTag(const std::string& path, const std::string& tag) {
    if (tag.empty()) return false;
    std::vector<std::string> tags = GetFileTagsStd(path);
    if (std::find(tags.begin(), tags.end(), tag) == tags.end()) {
        tags.push_back(tag);
    }
    return SetFinderTags(std::filesystem::absolute(path).string(), tags);
}

static bool RemoveFinderTag(const std::string& path, const std::string& tag) {
    std::vector<std::string> tags = GetFileTagsStd(path);
    const auto newEnd = std::remove(tags.begin(), tags.end(), tag);
    if (newEnd == tags.end()) {
        return false;
    }
    tags.erase(newEnd, tags.end());
    return SetFinderTags(std::filesystem::absolute(path).string(), tags);
}

static bool UpdateFinderTag(const std::string& path, const std::string& oldTag, const std::string& newTag) {
    if (newTag.empty()) return false;
    std::vector<std::string> tags = GetFileTagsStd(path);
    auto it = std::find(tags.begin(), tags.end(), oldTag);
    if (it == tags.end()) {
        return false;
    }

    *it = newTag;
    std::vector<std::string> deduped;
    deduped.reserve(tags.size());
    for (const auto& t : tags) {
        if (std::find(deduped.begin(), deduped.end(), t) == deduped.end()) {
            deduped.push_back(t);
        }
    }
    return SetFinderTags(std::filesystem::absolute(path).string(), deduped);
}

static void EnsureImageTextureLoaded(id<MTLDevice> device, ImageItem& image) {
    if (!image.isLoaded) {
        image.texture = LoadTextureFromFile(device, image.path);
        image.isLoaded = true;
    }
}

static void EnsureExifLoaded(ImageItem& image) {
    if (image.exifLoaded) return;
    image.exifEntries.clear();
    ExifData* exif = exif_data_new_from_file(image.path.c_str());
    if (!exif) {
        image.exifLoaded = true;
        return;
    }

    for (int i = 0; i < EXIF_IFD_COUNT; i++) {
        ExifContent* content = exif->ifd[i];
        if (!content) continue;
        for (unsigned int j = 0; j < content->count; j++) {
            ExifEntry* entry = content->entries[j];
            if (!entry) continue;
            char value[1024];
            exif_entry_get_value(entry, value, sizeof(value));
            if (!*value) continue;
            const char* tagName = exif_tag_get_name_in_ifd(entry->tag, exif_entry_get_ifd(entry));
            if (!tagName) continue;
            image.exifEntries.emplace_back(tagName, value);
        }
    }
    exif_data_unref(exif);
    image.exifLoaded = true;
}

int main(int, char**)
{
    // Setup Dear ImGui context
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO(); (void)io;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;  // Enable Keyboard Controls
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad;   // Enable Gamepad Controls

    // Setup style
    ImGui::StyleColorsDark();
    //ImGui::StyleColorsLight();

    // Load Fonts
    // - If no fonts are loaded, dear imgui will use the default font. You can also load multiple fonts and use ImGui::PushFont()/PopFont() to select them.
    // - AddFontFromFileTTF() will return the ImFont* so you can store it if you need to select the font among multiple.
    // - If the file cannot be loaded, the function will return a nullptr. Please handle those errors in your application (e.g. use an assertion, or display an error and quit).
    // - Use '#define IMGUI_ENABLE_FREETYPE' in your imconfig file to use Freetype for higher quality font rendering.
    // - Read 'docs/FONTS.md' for more instructions and details. If you like the default font but want it to scale better, consider using the 'ProggyVector' from the same author!
    // - Remember that in C/C++ if you want to include a backslash \ in a string literal you need to write a double backslash \\ !
    //style.FontSizeBase = 20.0f;
    //io.Fonts->AddFontDefault();
    //io.Fonts->AddFontFromFileTTF("c:\\Windows\\Fonts\\segoeui.ttf");
    //io.Fonts->AddFontFromFileTTF("../../misc/fonts/DroidSans.ttf");
    //io.Fonts->AddFontFromFileTTF("../../misc/fonts/Roboto-Medium.ttf");
    //io.Fonts->AddFontFromFileTTF("../../misc/fonts/Cousine-Regular.ttf");
    //ImFont* font = io.Fonts->AddFontFromFileTTF("c:\\Windows\\Fonts\\ArialUni.ttf");
    //IM_ASSERT(font != nullptr);

    // Setup window
    glfwSetErrorCallback(glfw_error_callback);
    if (!glfwInit())
        return 1;

    // Create window with graphics context
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    GLFWwindow* window = glfwCreateWindow(1280, 720, "PicKing", nullptr, nullptr);
    if (window == nullptr)
        return 1;

    id <MTLDevice> device = MTLCreateSystemDefaultDevice();
    id <MTLCommandQueue> commandQueue = [device newCommandQueue];

    // Setup Platform/Renderer backends
    ImGui_ImplGlfw_InitForOpenGL(window, true);
    ImGui_ImplMetal_Init(device);

    NSWindow *nswin = glfwGetCocoaWindow(window);
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    nswin.contentView.layer = layer;
    nswin.contentView.wantsLayer = YES;

    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor new];

    // Our state
    float clear_color[4] = {0.45f, 0.55f, 0.60f, 1.00f};
    std::string dir = browse_folder();

    LoadAllImages(device, dir);
    sort(g_images.begin(), g_images.end(), img_path_cmp);

    ImGuiStyle& style = ImGui::GetStyle();
    style.WindowRounding = 10.0f;
    style.ChildRounding = 8.0f;
    style.FrameRounding = 6.0f;
    style.GrabRounding = 6.0f;
    style.WindowPadding = ImVec2(12, 10);
    style.FramePadding = ImVec2(10, 6);

    static ImGuiKey keyBuffer = ImGuiKey_None;
    static bool isWaitingForKey = false;
    static char tagBuf[128] = "";
    static char mappingTagBuf[128] = "";
    static int editingTagIndex = -1;
    static char editTagBuf[128] = "";
    std::string status = "Ready";

    // Main loop
    while (!glfwWindowShouldClose(window))
    {
        @autoreleasepool
        {
            // Poll and handle events (inputs, window resize, etc.)
            // You can read the io.WantCaptureMouse, io.WantCaptureKeyboard flags to tell if dear imgui wants to use your inputs.
            // - When io.WantCaptureMouse is true, do not dispatch mouse input data to your main application, or clear/overwrite your copy of the mouse data.
            // - When io.WantCaptureKeyboard is true, do not dispatch keyboard input data to your main application, or clear/overwrite your copy of the keyboard data.
            // Generally you may always pass all inputs to dear imgui, and hide them from your application based on those two flags.
            glfwPollEvents();

            int width, height;
            glfwGetFramebufferSize(window, &width, &height);
            layer.drawableSize = CGSizeMake(width, height);
            id<CAMetalDrawable> drawable = [layer nextDrawable];

            id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(clear_color[0] * clear_color[3], clear_color[1] * clear_color[3], clear_color[2] * clear_color[3], clear_color[3]);
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
            renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
            renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
            id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
            [renderEncoder pushDebugGroup:@"ImGui demo"];

            // Start the Dear ImGui frame
            ImGui_ImplMetal_NewFrame(renderPassDescriptor);
            ImGui_ImplGlfw_NewFrame();
            ImGui::NewFrame();
            ImageItem* currentImage = GetCurrentImage();
            if (isWaitingForKey) {
                for (int n = ImGuiKey_NamedKey_BEGIN; n < ImGuiKey_NamedKey_END; n++) {
                    ImGuiKey key = (ImGuiKey)n;
                    if (ImGui::IsKeyPressed(key)) {
                        keyBuffer = key;
                        isWaitingForKey = false;
                        status = std::string("Captured key: ") + ImGui::GetKeyName(keyBuffer);
                        break;
                    }
                }
            }

            if (currentImage && !io.WantTextInput && !isWaitingForKey) {
                if (ImGui::IsKeyPressed(ImGuiKey_LeftArrow)) {
                    g_currentIndex = (g_currentIndex > 0) ? g_currentIndex - 1 : (int)g_images.size() - 1;
                    currentImage = GetCurrentImage();
                }
                if (ImGui::IsKeyPressed(ImGuiKey_RightArrow)) {
                    g_currentIndex = (g_currentIndex + 1) % (int)g_images.size();
                    currentImage = GetCurrentImage();
                }

                for (const auto& mapping : keyTagMappings) {
                    if (!ImGui::IsKeyPressed(mapping.first)) continue;
                    if (AddFinderTag(currentImage->path, mapping.second)) {
                        status = "Applied tag [" + mapping.second + "] to " + GetFileName(currentImage->path);
                    } else {
                        status = "Failed to apply tag.";
                    }
                    g_currentIndex = (g_currentIndex + 1) % (int)g_images.size();
                    currentImage = GetCurrentImage();
                    break;
                }
            }

            const ImVec2 display = io.DisplaySize;
            const float toolbarHeight = 66.0f;
            const float statusHeight = 30.0f;
            const float filmstripHeight = 148.0f;
            const float leftPanelWidth = 320.0f;
            const float rightPanelWidth = 340.0f;
            const float spacing = 8.0f;

            float workTop = toolbarHeight + spacing;
            float workBottom = display.y - filmstripHeight - statusHeight - spacing * 2.0f;
            float workHeight = std::max(120.0f, workBottom - workTop);
            float centerX = leftPanelWidth + spacing;
            float centerWidth = std::max(220.0f, display.x - leftPanelWidth - rightPanelWidth - spacing * 2.0f);

            ImGuiWindowFlags panelFlags = ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoCollapse;

            ImGui::SetNextWindowPos(ImVec2(0, 0));
            ImGui::SetNextWindowSize(ImVec2(display.x, toolbarHeight));
            ImGui::Begin("Toolbar", nullptr, panelFlags | ImGuiWindowFlags_NoTitleBar);
            if (ImGui::Button("Open Folder")) {
                std::string selectedDir = browse_folder();
                if (!selectedDir.empty()) {
                    dir = selectedDir;
                    LoadAllImages(device, dir);
                    sort(g_images.begin(), g_images.end(), img_path_cmp);
                    currentImage = GetCurrentImage();
                    status = "Loaded " + std::to_string(g_images.size()) + " images";
                }
            }
            ImGui::SameLine();
            ImGui::Text("Folder: %s", dir.empty() ? "(not selected)" : dir.c_str());
            ImGui::SameLine();
            ImGui::Separator();
            ImGui::SameLine();
            ImGui::Text("Total: %d", (int)g_images.size());

            if (currentImage) {
                ImGui::SameLine();
                if (ImGui::Button("< Prev")) {
                    g_currentIndex = (g_currentIndex > 0) ? g_currentIndex - 1 : (int)g_images.size() - 1;
                    currentImage = GetCurrentImage();
                }
                ImGui::SameLine();
                if (ImGui::Button("Next >")) {
                    g_currentIndex = (g_currentIndex + 1) % (int)g_images.size();
                    currentImage = GetCurrentImage();
                }
                ImGui::SameLine();
                ImGui::Text("Index: %d / %d", g_currentIndex + 1, (int)g_images.size());
            }
            ImGui::End();

            ImGui::SetNextWindowPos(ImVec2(0, workTop));
            ImGui::SetNextWindowSize(ImVec2(leftPanelWidth, workHeight));
            ImGui::Begin("Workflow", nullptr, panelFlags);
            ImGui::Text("Tagging Workspace");
            ImGui::Separator();
            if (!currentImage) {
                ImGui::TextWrapped("Please open a folder with JPG/JPEG images.");
            } else {
                ImGui::TextWrapped("%s", GetFileName(currentImage->path).c_str());
                ImGui::TextDisabled("Use Left/Right arrows to navigate quickly.");
                ImGui::Spacing();

                bool addByEnter = ImGui::InputTextWithHint("##tag-input", "Type a tag then press Enter", tagBuf, IM_ARRAYSIZE(tagBuf), ImGuiInputTextFlags_EnterReturnsTrue);
                bool addFromInput = ImGui::Button("Add Tag");
                if (ImGui::IsItemHovered()) ImGui::SetTooltip("Append this Finder tag to current image");
                if ((addByEnter || addFromInput) && std::strlen(tagBuf) > 0) {
                    if (AddFinderTag(currentImage->path, tagBuf)) {
                        status = std::string("Applied tag [") + tagBuf + "]";
                        tagBuf[0] = '\0';
                    } else {
                        status = "Failed to apply tag.";
                    }
                }

                ImGui::Spacing();
                ImGui::SeparatorText("Current Finder Tags");
                std::vector<std::string> currentTags = GetFileTagsStd(currentImage->path);
                if (currentTags.empty()) {
                    editingTagIndex = -1;
                    ImGui::TextDisabled("No tags yet");
                } else {
                    if (editingTagIndex >= (int)currentTags.size()) {
                        editingTagIndex = -1;
                    }
                    for (int i = 0; i < (int)currentTags.size(); ++i) {
                        const std::string& t = currentTags[i];
                        ImGui::PushID(i);

                        if (editingTagIndex == i) {
                            ImGui::SetNextItemWidth(150.0f);
                            bool commitByEnter = ImGui::InputText("##edit-tag", editTagBuf, IM_ARRAYSIZE(editTagBuf), ImGuiInputTextFlags_EnterReturnsTrue);
                            ImGui::SameLine();
                            bool commitByButton = ImGui::SmallButton("Save");
                            ImGui::SameLine();
                            bool cancelEdit = ImGui::SmallButton("Cancel");

                            if ((commitByEnter || commitByButton) && std::strlen(editTagBuf) > 0) {
                                if (UpdateFinderTag(currentImage->path, t, editTagBuf)) {
                                    status = "Updated tag [" + t + "] -> [" + std::string(editTagBuf) + "]";
                                } else {
                                    status = "Failed to update tag.";
                                }
                                editingTagIndex = -1;
                                editTagBuf[0] = '\0';
                            } else if (cancelEdit) {
                                editingTagIndex = -1;
                                editTagBuf[0] = '\0';
                            }
                        } else {
                            ImGui::Text("%s", t.c_str());
                            ImGui::SameLine();
                            if (ImGui::SmallButton("Edit")) {
                                editingTagIndex = i;
                                std::strncpy(editTagBuf, t.c_str(), IM_ARRAYSIZE(editTagBuf) - 1);
                                editTagBuf[IM_ARRAYSIZE(editTagBuf) - 1] = '\0';
                            }
                            ImGui::SameLine();
                            if (ImGui::SmallButton("Delete")) {
                                if (RemoveFinderTag(currentImage->path, t)) {
                                    status = "Deleted tag [" + t + "]";
                                } else {
                                    status = "Failed to delete tag.";
                                }
                                if (editingTagIndex == i) {
                                    editingTagIndex = -1;
                                    editTagBuf[0] = '\0';
                                }
                            }
                        }

                        ImGui::PopID();
                    }
                }

                ImGui::Spacing();
                ImGui::SeparatorText("Key To Tag Mapping");
                int mappingIndex = 0;
                for (auto it = keyTagMappings.begin(); it != keyTagMappings.end();) {
                    ImGui::PushID(mappingIndex++);
                    ImGui::Text("[%s] -> %s", ImGui::GetKeyName(it->first), it->second.c_str());
                    ImGui::SameLine();
                    if (ImGui::SmallButton("Delete")) {
                        it = keyTagMappings.erase(it);
                    } else {
                        ++it;
                    }
                    ImGui::PopID();
                }

                ImGui::Spacing();
                if (ImGui::Button(isWaitingForKey ? "Press any key..." : "Capture Shortcut Key")) {
                    isWaitingForKey = true;
                }
                if (keyBuffer != ImGuiKey_None) {
                    ImGui::SameLine();
                    ImGui::Text("Selected: %s", ImGui::GetKeyName(keyBuffer));
                }
                ImGui::InputTextWithHint("##mapping-tag", "Tag for this shortcut", mappingTagBuf, IM_ARRAYSIZE(mappingTagBuf));
                if (ImGui::Button("Add Mapping") && keyBuffer != ImGuiKey_None && std::strlen(mappingTagBuf) > 0) {
                    keyTagMappings[keyBuffer] = mappingTagBuf;
                    status = std::string("Mapped [") + ImGui::GetKeyName(keyBuffer) + "] -> " + mappingTagBuf;
                    keyBuffer = ImGuiKey_None;
                    mappingTagBuf[0] = '\0';
                }
            }
            ImGui::End();

            ImGui::SetNextWindowPos(ImVec2(centerX, workTop));
            ImGui::SetNextWindowSize(ImVec2(centerWidth, workHeight));
            ImGui::Begin("Preview", nullptr, panelFlags);
            if (!currentImage) {
                ImGui::TextWrapped("No image available.");
            } else {
                EnsureImageTextureLoaded(device, *currentImage);
                ImGui::TextWrapped("%s", currentImage->path.c_str());
                ImGui::Separator();
                if (currentImage->texture) {
                    float imgW = (float)currentImage->texture.width;
                    float imgH = (float)currentImage->texture.height;
                    ImVec2 avail = ImGui::GetContentRegionAvail();
                    float scale = std::min(avail.x / imgW, avail.y / imgH);
                    if (scale > 0.0f) {
                        ImVec2 displaySize(imgW * scale, imgH * scale);
                        float xOffset = std::max(0.0f, (avail.x - displaySize.x) * 0.5f);
                        ImGui::SetCursorPosX(ImGui::GetCursorPosX() + xOffset);
                        ImGui::Image((ImTextureID)currentImage->texture, displaySize);
                    }
                } else {
                    ImGui::TextDisabled("Image load failed.");
                }
            }
            ImGui::End();

            ImGui::SetNextWindowPos(ImVec2(centerX + centerWidth + spacing, workTop));
            ImGui::SetNextWindowSize(ImVec2(rightPanelWidth, workHeight));
            ImGui::Begin("Metadata", nullptr, panelFlags);
            if (!currentImage) {
                ImGui::TextDisabled("No metadata.");
            } else {
                EnsureExifLoaded(*currentImage);
                ImGui::Text("EXIF");
                ImGui::Separator();
                ImGui::BeginChild("exif-list", ImVec2(0, 0), true);
                if (currentImage->exifEntries.empty()) {
                    ImGui::TextDisabled("No EXIF data found.");
                } else {
                    for (const auto& kv : currentImage->exifEntries) {
                        ImGui::TextWrapped("%s: %s", kv.first.c_str(), kv.second.c_str());
                    }
                }
                ImGui::EndChild();
            }
            ImGui::End();

            ImGui::SetNextWindowPos(ImVec2(0, display.y - statusHeight - filmstripHeight));
            ImGui::SetNextWindowSize(ImVec2(display.x, filmstripHeight));
            ImGui::Begin("Filmstrip", nullptr, panelFlags);
            ImGui::BeginChild("filmstrip-scroll", ImVec2(0, 0), false, ImGuiWindowFlags_HorizontalScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
            const float thumbSize = 92.0f;
            const float thumbGap = 8.0f;

            if (ImGui::IsWindowHovered(ImGuiHoveredFlags_AllowWhenBlockedByActiveItem)) {
                const float scrollStep = thumbSize + thumbGap;
                float delta = 0.0f;
                if (io.MouseWheel != 0.0f) {
                    delta += -io.MouseWheel * scrollStep;
                }
                if (io.MouseWheelH != 0.0f) {
                    delta += -io.MouseWheelH * scrollStep;
                }
                if (delta != 0.0f) {
                    ImGui::SetScrollX(ImGui::GetScrollX() + delta);
                }
            }

            for (int i = 0; i < (int)g_images.size(); i++) {
                auto& img = g_images[i];
                ImGui::PushID(i);

                ImVec2 topLeft = ImGui::GetCursorScreenPos();
                ImGui::BeginGroup();
                ImGui::InvisibleButton("thumb-hit", ImVec2(thumbSize, thumbSize));
                if (ImGui::IsItemClicked()) {
                    g_currentIndex = i;
                    currentImage = GetCurrentImage();
                }

                id<MTLTexture> drawTex = img.thumbnail;
                if (!drawTex) {
                    if (!img.isLoaded) {
                        EnsureImageTextureLoaded(device, img);
                    }
                    drawTex = img.texture;
                }

                ImDrawList* drawList = ImGui::GetWindowDrawList();
                drawList->AddRectFilled(topLeft, ImVec2(topLeft.x + thumbSize, topLeft.y + thumbSize), IM_COL32(35, 35, 35, 255), 4.0f);
                if (drawTex) {
                    float tw = (float)drawTex.width;
                    float th = (float)drawTex.height;
                    float tscale = std::min(thumbSize / tw, thumbSize / th);
                    ImVec2 drawSize(tw * tscale, th * tscale);
                    ImVec2 drawPos(topLeft.x + (thumbSize - drawSize.x) * 0.5f, topLeft.y + (thumbSize - drawSize.y) * 0.5f);
                    drawList->AddImage((ImTextureID)drawTex, drawPos, ImVec2(drawPos.x + drawSize.x, drawPos.y + drawSize.y));
                } else {
                    drawList->AddText(ImVec2(topLeft.x + 28.0f, topLeft.y + 36.0f), IM_COL32(180, 180, 180, 255), "N/A");
                }

                if (i == g_currentIndex) {
                    drawList->AddRect(topLeft, ImVec2(topLeft.x + thumbSize, topLeft.y + thumbSize), IM_COL32(255, 124, 72, 255), 4.0f, 0, 3.0f);
                } else {
                    drawList->AddRect(topLeft, ImVec2(topLeft.x + thumbSize, topLeft.y + thumbSize), IM_COL32(92, 92, 92, 255), 4.0f, 0, 1.0f);
                }

                ImGui::SetCursorScreenPos(ImVec2(topLeft.x, topLeft.y + thumbSize + 2.0f));
                ImGui::TextDisabled("%d", i + 1);
                ImGui::EndGroup();

                if (i + 1 < (int)g_images.size()) {
                    ImGui::SameLine(0.0f, thumbGap);
                }
                ImGui::PopID();
            }
            ImGui::EndChild();
            ImGui::End();

            ImGui::SetNextWindowPos(ImVec2(0, display.y - statusHeight));
            ImGui::SetNextWindowSize(ImVec2(display.x, statusHeight));
            ImGui::Begin("Status", nullptr, panelFlags | ImGuiWindowFlags_NoTitleBar);
            ImGui::Text("Hints: Left/Right = Navigate | Shortcut Key = Apply mapped tag and jump next");
            ImGui::SameLine();
            ImGui::TextDisabled(" | %s", status.c_str());
            ImGui::End();

            // Rendering
            ImGui::Render();
            ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, renderEncoder);

            [renderEncoder popDebugGroup];
            [renderEncoder endEncoding];

            [commandBuffer presentDrawable:drawable];
            [commandBuffer commit];
        }
    }
    
    // Cleanup
    ImGui_ImplMetal_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    ImGui::DestroyContext();

    glfwDestroyWindow(window);
    glfwTerminate();

    return 0;
}
