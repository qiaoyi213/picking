#include "imgui.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_metal.h"

#include <stdio.h>
#include <filesystem>
#include <vector>
#include <string>
#include <fstream>
#include <iostream>

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
    id<MTLTexture> texture;
};

static std::vector<ImageItem> g_images;
static int g_currentIndex = 0;


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
    for (auto& entry : std::filesystem::directory_iterator(folder)) {
        if (entry.is_regular_file()) {
            auto ext = entry.path().extension().string();
            if (ext == ".jpg" || ext == ".JPG" || ext == ".jpeg") {
                ImageItem item;
                item.path = entry.path().string();
                std::cout<<"GET"<<std::endl;
                item.isLoaded = false;
                g_images.push_back(item);

                // item.texture = LoadTextureFromFile(device, item.path);
                /*
                if (item.texture) {
                    g_images.push_back(item);
                }
                */
                std::cout<<"LOAD"<<std::endl;
            }
        }
    }
}

static void glfw_error_callback(int error, const char* description)
{
    fprintf(stderr, "Glfw Error %d: %s\n", error, description);
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
    GLFWwindow* window = glfwCreateWindow(1280, 720, "Dear ImGui GLFW+Metal example", nullptr, nullptr);
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

            
            {
                ImGui::Begin("Image Viewer");

                if (!g_images.empty()) {
                    auto& img = g_images[g_currentIndex];
                    
                    if(!img.isLoaded){
                        img.texture = LoadTextureFromFile(device, img.path);
                        img.isLoaded = true;
                    }

                    ImGui::Text("File: %s", img.path.c_str());
                    ImVec2 avail = ImGui::GetContentRegionAvail();
                    ImGui::Image((ImTextureID)img.texture, avail);

                    // 鍵盤操作
                    if (ImGui::IsKeyPressed(ImGuiKey_LeftArrow)) {
                        g_currentIndex = (g_currentIndex > 0) ? g_currentIndex - 1 : g_images.size()-1;
                    }
                    if (ImGui::IsKeyPressed(ImGuiKey_RightArrow)) {
                        g_currentIndex = (g_currentIndex+1) % g_images.size();
                    }

                    if (ImGui::IsKeyPressed(ImGuiKey_1)) {
                        std::cout<<"1"<<std::endl;
                        std::vector<std::string> tags = {"1"};
                        std::cout<< std::filesystem::absolute(img.path)<<std::endl;
                        if (SetFinderTags(std::filesystem::absolute(img.path), tags)) {
                            std::cout << "Tags set successfully!\n";
                        }
                        g_currentIndex = (g_currentIndex+1) % g_images.size();
                    }
                    if (ImGui::IsKeyPressed(ImGuiKey_2)) {
                        std::vector<std::string> tags = {"2"};
                        std::cout<< std::filesystem::absolute(img.path)<<std::endl;
                        if (SetFinderTags(std::filesystem::absolute(img.path), tags)) {
                            std::cout << "Tags set successfully!\n";
                        }
                        g_currentIndex = (g_currentIndex+1) % g_images.size();
                    }
                    if (ImGui::IsKeyPressed(ImGuiKey_3)) {
                        std::vector<std::string> tags = {"3"};
                        std::cout<< std::filesystem::absolute(img.path)<<std::endl;
                        if (SetFinderTags(std::filesystem::absolute(img.path), tags)) {
                            std::cout << "Tags set successfully!\n";
                        }
                        g_currentIndex = (g_currentIndex+1) % g_images.size();
                    }
                    if (ImGui::IsKeyPressed(ImGuiKey_4)) {
                        std::vector<std::string> tags = {"4"};
                        std::cout<< std::filesystem::absolute(img.path)<<std::endl;
                        if (SetFinderTags(std::filesystem::absolute(img.path), tags)) {
                            std::cout << "Tags set successfully!\n";
                        }
                        g_currentIndex = (g_currentIndex+1) % g_images.size();
                    }
                    if (ImGui::IsKeyPressed(ImGuiKey_5)) {
                        std::vector<std::string> tags = {"5"};
                        std::cout<< std::filesystem::absolute(img.path)<<std::endl;
                        if (SetFinderTags(std::filesystem::absolute(img.path), tags)) {
                            std::cout << "Tags set successfully!\n";
                        }
                        g_currentIndex = (g_currentIndex+1) % g_images.size();
                    }
                    if (ImGui::IsKeyPressed(ImGuiKey_6)) {
                        std::vector<std::string> tags = {"6"};
                        std::cout<< std::filesystem::absolute(img.path)<<std::endl;
                        if (SetFinderTags(std::filesystem::absolute(img.path), tags)) {
                            std::cout << "Tags set successfully!\n";
                        }
                        g_currentIndex = (g_currentIndex+1) % g_images.size();
                    }

                } else {
                    ImGui::Text("No images found in ./images");
                }

                ImGui::End();

            }

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
