using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace Motifs;

// Scrollable cards for the context preview. Markdown stays in the text box.
sealed class ContextCardPane : Panel
{
    internal static readonly Color Card = Color.FromArgb(44, 44, 48);
    internal static readonly Color Ink = Color.FromArgb(236, 236, 238);
    internal static readonly Color Secondary = Color.FromArgb(170, 170, 176);
    internal static readonly Color Dim = Color.FromArgb(140, 140, 146);
    internal static readonly Color Warning = Color.FromArgb(255, 159, 10);
    internal static readonly Color Danger = Color.FromArgb(255, 99, 88);
    internal static readonly Color ClipInk = Color.FromArgb(191, 128, 255);
    internal readonly Font BadgeFont = new("Consolas", 8, FontStyle.Bold);
    internal readonly Font BodyFont = new("Segoe UI", 10);
    internal readonly Font MonoFont = new("Consolas", 9);
    internal readonly Font SecondaryFont = new("Segoe UI", 9);
    internal readonly Font HeadingFont = new("Segoe UI", 10, FontStyle.Bold);
    bool arranging;

    internal ContextCardPane()
    {
        AutoScroll = true;
        DoubleBuffered = true;
        Disposed += (_, _) =>
        {
            BadgeFont.Dispose();
            BodyFont.Dispose();
            MonoFont.Dispose();
            SecondaryFont.Dispose();
            HeadingFont.Dispose();
        };
    }

    internal void Show(ContextReview.ContextSheet sheet, string empty, bool included)
    {
        SuspendLayout();
        while (Controls.Count > 0)
        {
            Control child = Controls[0];
            Controls.RemoveAt(0);
            child.Dispose();
        }
        if (sheet.Cards.Count == 0 && sheet.More.Length == 0)
        {
            Controls.Add(new Label
            {
                Text = empty,
                AutoSize = true,
                ForeColor = Secondary,
                Font = SecondaryFont,
                Padding = new Padding(8, 28, 8, 8),
            });
        }
        else
        {
            foreach (var card in sheet.Cards) Controls.Add(new ContextCardFace(card, this, included));
            if (sheet.More.Length > 0)
            {
                Controls.Add(new Label
                {
                    Text = sheet.More,
                    AutoSize = true,
                    ForeColor = Secondary,
                    Font = SecondaryFont,
                    Padding = new Padding(2, 4, 2, 8),
                });
            }
        }
        ResumeLayout(true);
        AutoScrollPosition = new Point(0, 0);
    }

    internal Color ToneColor(ContextReview.ContextTone tone, bool included)
    {
        if (!included) return Dim;
        return tone switch
        {
            ContextReview.ContextTone.Neutral => Secondary,
            ContextReview.ContextTone.Warning => Warning,
            ContextReview.ContextTone.Danger => Danger,
            _ => throw new InvalidOperationException($"Unexpected tone {tone}."),
        };
    }

    internal static Color Tint(Color back, Color color)
    {
        const double amount = 0.14;
        return Color.FromArgb(
            (int)(back.R * (1 - amount) + color.R * amount),
            (int)(back.G * (1 - amount) + color.G * amount),
            (int)(back.B * (1 - amount) + color.B * amount));
    }

    protected override void OnLayout(LayoutEventArgs levent)
    {
        if (arranging) return;
        arranging = true;
        try
        {
            int width = Math.Max(40, ClientSize.Width - SystemInformation.VerticalScrollBarWidth);
            int y = 0;
            foreach (Control child in Controls)
            {
                child.Left = 0;
                if (child is ContextCardFace face) face.Reflow(width);
                else
                {
                    child.MaximumSize = new Size(width, 0);
                    Size preferred = child.GetPreferredSize(new Size(width, 0));
                    child.Width = width;
                    child.Height = preferred.Height;
                }
                child.Top = y;
                y += child.Height + 8;
            }
            var span = new Size(0, Math.Max(0, y));
            if (AutoScrollMinSize != span) AutoScrollMinSize = span;
        }
        finally { arranging = false; }
    }
}

sealed class ContextCardFace : Panel
{
    const int Pad = 10;
    readonly ContextReview.ContextCard card;
    readonly ContextCardPane pane;
    readonly bool included;

    internal ContextCardFace(ContextReview.ContextCard card, ContextCardPane pane, bool included)
    {
        this.card = card;
        this.pane = pane;
        this.included = included;
        DoubleBuffered = true;
        ResizeRedraw = true;
        BackColor = pane.BackColor;
    }

    int Inner => Math.Max(24, Width - Pad * 2);

    internal void Reflow(int width)
    {
        Width = Math.Max(40, width);
        int height = Math.Max(Pad * 2, Place(null, false));
        if (Height != height) Height = height;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (Width < 4 || Height < 4) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (var brush = new SolidBrush(ContextCardPane.Card))
        using (var path = Round(new Rectangle(0, 0, Width - 1, Height - 1), 8))
            e.Graphics.FillPath(brush, path);
        Place(e.Graphics, true);
    }

    int Place(Graphics? graphics, bool draw)
    {
        int y = Pad;
        bool gap = false;
        Color ink = included ? ContextCardPane.Ink : ContextCardPane.Dim;
        Color secondary = included ? ContextCardPane.Secondary : ContextCardPane.Dim;
        if (card.Heading.Length > 0)
        {
            if (gap) y += 4;
            gap = true;
            y += DrawBlock(graphics, card.Heading, pane.HeadingFont, ink, Pad, y, Inner, draw, 3);
        }
        if (card.Marks.Count > 0 || card.Aside.Length > 0 || card.When.Length > 0 || (card.InlineBody && card.Body.Length > 0))
        {
            if (gap) y += 4;
            gap = true;
            y += DrawTop(graphics, y, draw, ink, secondary);
        }
        if (!card.InlineBody && card.Body.Length > 0)
        {
            if (gap) y += 4;
            gap = true;
            y += DrawBlock(graphics, card.Body, card.Mono ? pane.MonoFont : pane.BodyFont, ink, Pad, y, Inner, draw, 6);
        }
        if (card.Foot.Length > 0)
        {
            if (gap) y += 4;
            gap = true;
            y += DrawBlock(graphics, card.Foot, pane.SecondaryFont, secondary, Pad, y, Inner, draw, 3);
        }
        foreach (var pair in card.Pairs)
        {
            if (gap) y += 6;
            gap = true;
            int keyHeight = DrawBlock(graphics, pair.Key, pane.SecondaryFont, secondary, Pad, y, 110, draw, 2);
            int valueHeight = DrawBlock(graphics, pair.Value, pane.BodyFont, ink, Pad + 118, y, Math.Max(24, Inner - 118), draw, 4);
            y += Math.Max(keyHeight, valueHeight);
        }
        return y + Pad;
    }

    int DrawTop(Graphics? graphics, int y, bool draw, Color ink, Color secondary)
    {
        int x = Pad;
        int badgeHeight = 0;
        foreach (var mark in card.Marks)
        {
            var textSize = TextRenderer.MeasureText(mark.Text, pane.BadgeFont, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            int width = textSize.Width + 12;
            int height = textSize.Height + 4;
            if (draw && graphics != null)
            {
                Color tone = pane.ToneColor(mark.Tone, included);
                using var back = new SolidBrush(ContextCardPane.Tint(ContextCardPane.Card, tone));
                using var path = Round(new Rectangle(x, y, width, height), 4);
                graphics.FillPath(back, path);
                TextRenderer.DrawText(graphics, mark.Text, pane.BadgeFont, new Rectangle(x + 6, y + 2, textSize.Width + 2, textSize.Height), tone, TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            }
            x += width + 6;
            badgeHeight = Math.Max(badgeHeight, height);
        }
        int whenWidth = card.When.Length == 0 ? 0 : TextRenderer.MeasureText(card.When, pane.SecondaryFont, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Width + 2;
        int asideNatural = card.Aside.Length == 0 ? 0 : TextRenderer.MeasureText(card.Aside, pane.SecondaryFont, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Width + 8;
        int right = Width - Pad;
        int room = Math.Max(0, right - x - whenWidth - (whenWidth > 0 ? 8 : 0));
        int asideWidth = card.Aside.Length == 0 ? 0 : asideNatural;
        int bodyWidth = 0;
        if (card.InlineBody && card.Body.Length > 0)
        {
            asideWidth = Math.Min(asideWidth, Math.Max(0, room / 3));
            bodyWidth = Math.Max(24, room - asideWidth - (asideWidth > 0 ? 6 : 0));
        }
        else asideWidth = room;
        int bodyHeight = 0;
        if (card.InlineBody && card.Body.Length > 0)
        {
            bodyHeight = DrawBlock(graphics, card.Body, card.Mono ? pane.MonoFont : pane.BodyFont, ink, x, y, bodyWidth, draw, 2);
            x += bodyWidth + 6;
        }
        int asideHeight = 0;
        if (card.Aside.Length > 0 && asideWidth > 0)
            asideHeight = DrawBlock(graphics, card.Aside, pane.SecondaryFont, secondary, x, y + 2, asideWidth, draw, 1);
        int whenHeight = 0;
        if (card.When.Length > 0)
        {
            Color whenColor = card.Clip && included ? ContextCardPane.ClipInk : secondary;
            whenHeight = DrawBlock(graphics, card.When, pane.SecondaryFont, whenColor, right - whenWidth, y + 2, whenWidth, draw, 1);
        }
        return Math.Max(badgeHeight, Math.Max(bodyHeight, Math.Max(asideHeight, whenHeight)));
    }

    static int DrawBlock(Graphics? graphics, string text, Font font, Color color, int x, int y, int width, bool draw, int maxLines)
    {
        width = Math.Max(1, width);
        var flags = maxLines == 1
            ? TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding | TextFormatFlags.Left
            : TextFormatFlags.WordBreak | TextFormatFlags.NoPadding | TextFormatFlags.Left | TextFormatFlags.Top;
        int height = TextRenderer.MeasureText(text, font, new Size(width, int.MaxValue), flags).Height;
        if (maxLines > 1)
        {
            int cap = Math.Max(font.Height, font.Height * maxLines);
            if (height > cap) height = cap;
        }
        if (draw && graphics != null)
            TextRenderer.DrawText(graphics, text, font, new Rectangle(x, y, width, height), color, flags | TextFormatFlags.EndEllipsis);
        return Math.Max(font.Height, height);
    }

    static GraphicsPath Round(Rectangle bounds, int radius)
    {
        int diameter = radius * 2;
        var path = new GraphicsPath();
        if (bounds.Width < diameter || bounds.Height < diameter)
        {
            path.AddRectangle(bounds);
            return path;
        }
        path.AddArc(bounds.X, bounds.Y, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Y, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}
