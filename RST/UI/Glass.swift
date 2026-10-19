import SwiftUI

/// Дизайн приложения (как «Настройки чатов → Дизайн» в Android): классический —
/// как в веб-версии, Liquid Glass — оформление iOS 26: стеклянные панели,
/// кнопки и сообщения. На iOS до 26 стекло — полупрозрачным материалом.
enum DesignMode: String, CaseIterable {
    case classic
    case glass

    var title: String {
        switch self {
        case .classic: return "Классический"
        case .glass: return "Liquid Glass"
        }
    }
}

extension ChatAppearance {
    var isGlass: Bool { design == .glass }

    /// Настоящее стекло iOS 26 (а не приближение материалом).
    static var nativeGlass: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}

/// Стеклянная подложка в форме shape; tint — окраска стекла.
struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(glass(), in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func glass() -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
    #endif

    private func fallback(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.75)) }
                }
            }
            .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.8))
    }
}

extension View {
    /// Подложка: в классическом дизайне — classic, в Liquid Glass — стекло.
    func rstSurface<S: Shape, Style: ShapeStyle>(_ shape: S, classic: Style, tint: Color? = nil,
                                                 interactive: Bool = false) -> some View {
        modifier(SurfaceModifier(shape: shape, classic: AnyShapeStyle(classic), tint: tint, interactive: interactive))
    }

    /// Панель во всю ширину (ответ, закреп, запись, выделение).
    func rstBar<Style: ShapeStyle>(classic: Style) -> some View {
        modifier(BarModifier(classic: AnyShapeStyle(classic)))
    }

    /// Круглая плавающая кнопка: в Liquid Glass — стеклянный кружок.
    func rstFloatingCircle() -> some View {
        modifier(FloatingCircleModifier())
    }

    /// Значок-кнопка у поля ввода: в Liquid Glass — на стеклянном кружке,
    /// в классическом — без подложки, как раньше.
    func glassCircleOnly() -> some View {
        modifier(GlassOnlyCircleModifier())
    }
}

private struct GlassOnlyCircleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if ChatAppearance.shared.isGlass {
            content.modifier(GlassBackground(shape: Circle(), interactive: true))
        } else {
            content
        }
    }
}

private struct SurfaceModifier<S: Shape>: ViewModifier {
    let shape: S
    let classic: AnyShapeStyle
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if ChatAppearance.shared.isGlass {
            content.modifier(GlassBackground(shape: shape, tint: tint, interactive: interactive))
        } else {
            content.background(classic, in: shape)
        }
    }
}

private struct BarModifier: ViewModifier {
    let classic: AnyShapeStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        if ChatAppearance.shared.isGlass {
            // Плавающая стеклянная полоса с отступами от краёв
            content
                .modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        } else {
            content.background(classic)
        }
    }
}

private struct FloatingCircleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if ChatAppearance.shared.isGlass {
            content.modifier(GlassBackground(shape: Circle(), interactive: true))
        } else {
            content
                .background(Circle().fill(Theme.card))
                .overlay(Circle().stroke(Theme.outline))
        }
    }
}

/// Нижняя панель вкладок: в Liquid Glass на iOS 26 сворачивается при прокрутке,
/// в классическом — непрозрачная, как раньше.
struct TabBarDesign: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if ChatAppearance.shared.isGlass {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.tabBarMinimizeBehavior(.onScrollDown)
            } else {
                content
            }
            #else
            content
            #endif
        } else {
            content.toolbarBackground(.visible, for: .tabBar)
        }
    }
}

/// Верхняя панель экрана: в классическом — непрозрачная, в Liquid Glass — системное стекло.
struct NavigationBarDesign: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbarBackground(ChatAppearance.shared.isGlass ? .automatic : .visible, for: .navigationBar)
    }
}
