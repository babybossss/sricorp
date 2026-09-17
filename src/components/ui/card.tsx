import * as React from "react";
import { cn } from "@/lib/utils";

const Card = React.forwardRef<HTMLDivElement, React.HTMLAttributes<HTMLDivElement>>(
  ({ className, ...props }, ref) => (
    <div ref={ref} className={cn("rounded-card border border-line bg-surface shadow-card", className)} {...props} />
  )
);
Card.displayName = "Card";

const CardBody = React.forwardRef<HTMLDivElement, React.HTMLAttributes<HTMLDivElement>>(
  ({ className, ...props }, ref) => <div ref={ref} className={cn("p-[18px_20px]", className)} {...props} />
);
CardBody.displayName = "CardBody";

const CardTitle = React.forwardRef<HTMLDivElement, React.HTMLAttributes<HTMLDivElement>>(
  ({ className, ...props }, ref) => <div ref={ref} className={cn("text-h2 font-semibold", className)} {...props} />
);
CardTitle.displayName = "CardTitle";

/** ป้ายกำกับเล็กเหนือตัวเลข — ศัพท์อังกฤษต่อท้ายใช้ <span className="text-ink-400"> */
const CardLabel = React.forwardRef<HTMLDivElement, React.HTMLAttributes<HTMLDivElement>>(
  ({ className, ...props }, ref) => <div ref={ref} className={cn("text-sm text-ink-600", className)} {...props} />
);
CardLabel.displayName = "CardLabel";

export { Card, CardBody, CardTitle, CardLabel };
