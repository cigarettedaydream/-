import SwiftUI

/// ACRCloud 识曲服务配置页
struct SettingsView: View {
    @AppStorage("acr_access_key_v2") private var accessKey = ACRConfiguration.defaultAccessKey
    @AppStorage("acr_secret_key_v2") private var secretKey = ACRConfiguration.defaultSecretKey
    @AppStorage("acr_api_host_v2") private var apiHost = ACRConfiguration.defaultHost
    @AppStorage(LyricsSource.storageKey) private var lyricsSourceRaw = LyricsSource.current.rawValue
    @Environment(\.dismiss) private var dismiss

    private let knownHosts = [
        "identify-cn-north-1.acrcloud.cn",
        "identify-ap-southeast-1.acrcloud.com",
        "identify-ap-northeast-1.acrcloud.com",
        "identify-eu-west-1.acrcloud.com",
        "identify-us-west-2.acrcloud.com",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Link(destination: URL(string: "https://www.acrcloud.cn/")!) {
                        Label("注册 ACRCloud（acrcloud.cn）", systemImage: "link")
                    }
                    Link(destination: URL(string: "https://console.acrcloud.cn/audio-recognition")!) {
                        Label("打开控制台 · Audio & Video Recognition", systemImage: "wrench.and.screwdriver")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("获取 Key 教程（免费额度，每天 100 次）：").font(.caption.bold())
                        Text("1. 在 acrcloud.cn 注册并登录\n2. 控制台「音视频识别 / Audio & Video Recognition」→「添加项目」，类型选「听歌识曲」\n3. 项目「集成(Integration)」页复制 Access Key、Secret Key；API Host 选对应区域（中国大陆为 identify-cn-north-1.acrcloud.cn）\n4. 把三者填到上面即可")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("识曲服务 · ACRCloud")
                }

                Section {
                    TextField("Access Key", text: $accessKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Secret Key", text: $secretKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("密钥")
                } footer: {
                    Text("来自 ACRCloud Console →「Audio & Video Recognition」→ 项目页（Secret Key 需点击显示后复制）。")
                }

                Section {
                    TextField("API Host", text: $apiHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("常用区域", selection: $apiHost) {
                        ForEach(knownHosts, id: \.self) { host in
                            Text(host).tag(host)
                        }
                    }
                } header: {
                    Text("服务节点")
                } footer: {
                    Text("必须与你项目所在区域一致（控制台项目页会显示 “ACRCloud API Host”）。区域不对会报 3001 Invalid Access Key。")
                }

                Section {
                    Picker("歌词来源", selection: $lyricsSourceRaw) {
                        ForEach(LyricsSource.allCases) { source in
                            Text(source.label).tag(source.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("歌词")
                } footer: {
                    Text("网易云歌词更丰富（含中文歌），假名/罗马音仅对日语歌词显示。")
                }

                Section {
                    Text("免费账户每天 100 次识别额度；每次识别消耗一段约 6 秒的录音样本。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("恢复内置默认值", role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: "acr_access_key_v2")
                        UserDefaults.standard.removeObject(forKey: "acr_secret_key_v2")
                        UserDefaults.standard.removeObject(forKey: "acr_api_host_v2")
                        accessKey = ACRConfiguration.defaultAccessKey
                        secretKey = ACRConfiguration.defaultSecretKey
                        apiHost = ACRConfiguration.defaultHost
                    }
                } header: {
                    Text("额度说明")
                }
            }
            .navigationTitle("识曲服务设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
