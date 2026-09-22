import SwiftUI

struct SizeReaderModifier<Value: Equatable & Sendable>: ViewModifier {
  @Binding var value: Value
  let mapper: @Sendable (CGSize) -> Value

  func body(content: Content) -> some View {
    content.onGeometryChange(for: Value.self) { [mapper] proxy in
      mapper(proxy.size)
    } action: { newValue in
      value = newValue
    }
  }
}

extension View {
  func readWidth(_ value: Binding<CGFloat>) -> some View {
    modifier(SizeReaderModifier(value: value, mapper: \.width))
  }

  func readHeight(_ value: Binding<CGFloat>) -> some View {
    modifier(SizeReaderModifier(value: value, mapper: \.height))
  }
}
