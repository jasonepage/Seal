import SwiftUI

/// Create a group from forged friends only (FR-10).
struct NewGroupView: View {
    let myRoot: RootIdentity
    @Bindable var chatEngine: ChatEngine
    @Bindable var friendStore: FriendStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var creating = false

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                VStack(spacing: 16) {
                    TextField("Group name", text: $name)
                        .textFieldStyle(.plain)
                        .padding()
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                    if friendStore.friends.isEmpty {
                        Spacer()
                        Text("You need forged friends to start a group.")
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                    } else {
                        List {
                            ForEach(friendStore.friends) { friend in
                                Button {
                                    if selected.contains(friend.id) { selected.remove(friend.id) }
                                    else { selected.insert(friend.id) }
                                } label: {
                                    HStack {
                                        IdentityRing(displayName: friend.identity.displayName,
                                                     tier: friend.identity.tier, size: 36)
                                        Text(friend.identity.displayName)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Image(systemName: selected.contains(friend.id)
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected.contains(friend.id)
                                                             ? SealTheme.brass : .white.opacity(0.3))
                                    }
                                }
                                .listRowBackground(Color.white.opacity(0.05))
                            }
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        creating = true
                        Task {
                            _ = await chatEngine.createGroup(
                                name: name.trimmingCharacters(in: .whitespaces),
                                friendHashes: Array(selected),
                                myRoot: myRoot)
                            dismiss()
                        }
                    }
                    .disabled(creating || selected.isEmpty
                              || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .tint(SealTheme.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
