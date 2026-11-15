import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var historyStore: HistoryStore

    var body: some View {
        NavigationStack {
            List {
                if !historyStore.searchHistory.isEmpty {
                    Section {
                        ForEach(historyStore.searchHistory) { item in
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(item.keyword)
                            }
                        }
                        .onDelete { indexSet in
                            for idx in indexSet {
                                historyStore.searchHistory.remove(at: idx)
                            }
                        }
                    } header: {
                        HStack {
                            Text("搜索历史")
                            Spacer()
                            Button("清空") {
                                historyStore.clearSearchHistory()
                            }
                            .font(.caption)
                        }
                    }
                }

                if !historyStore.recentSongs.isEmpty {
                    Section("最近查看") {
                        ForEach(historyStore.recentSongs) { song in
                            NavigationLink(value: song) {
                                HStack {
                                    Text(song.name)
                                    Spacer()
                                    Text(song.singer)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史")
            .navigationDestination(for: Song.self) { song in
                SongDetailView(song: song)
            }
        }
    }
}

#Preview {
    HistoryView()
}
