import { CommentThread, CommentType } from "@/components/ui/reddit-nested-thread-reply";

// Sample data for the discussion thread
const sampleComments: CommentType[] = [
  {
    id: 1,
    author: "techguru42",
    content: "This is a really interesting discussion about React components. I've been working with similar patterns and found that proper state management is crucial for nested structures like this.",
    timestamp: "2h",
    upvotes: 24,
    downvotes: 2,
    replies: [
      {
        id: 2,
        author: "devninja",
        content: "Absolutely agree! What state management solution do you recommend for deeply nested components?",
        timestamp: "1h",
        upvotes: 8,
        downvotes: 0,
        replies: [
          {
            id: 3,
            author: "techguru42",
            content: "I usually go with Zustand for simpler cases, but Redux Toolkit for more complex applications. The key is avoiding prop drilling.",
            timestamp: "45m",
            upvotes: 12,
            downvotes: 1,
            replies: []
          }
        ]
      },
      {
        id: 4,
        author: "reactfan",
        content: "Have you tried using React Context for this? I find it works well for theme management in nested components.",
        timestamp: "30m",
        upvotes: 5,
        downvotes: 0,
        replies: []
      }
    ]
  },
  {
    id: 5,
    author: "designerdev",
    content: "The UI looks great! Really clean design. How did you handle the responsive behavior on mobile?",
    timestamp: "3h",
    upvotes: 15,
    downvotes: 0,
    replies: []
  }
];

// The demo component that renders the CommentThread
const CommentThreadDemo = () => {
  return (
    <div className="bg-background text-foreground w-full min-h-screen">
      <div className="text-center space-y-2 pt-12 pb-6">
        <h1 className="text-3xl font-bold">Discussion Thread</h1>
        <p className="text-muted-foreground">
          A Reddit-style nested comment system with voting and replies.
        </p>
      </div>
      <CommentThread initialComments={sampleComments} />
    </div>
  );
};

export default CommentThreadDemo;
