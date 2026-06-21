- [ ] Implement microphone capture and audio recording.
- [ ] Check if migration logic for resolvedImageUrl and imageUrl is still needed (see didChangeModel).

- [?] Implement different logic for preserving images:
Let's think together to implement different logic to preserve images. Right now we preserve a set number of images based on a retention policy. We could consider implementing a more dynamic approach, such as:

 **Time-Based Retention**: Instead of keeping a fixed number of images, we could implement a time-based retention policy where images older than a certain age (e.g., 30 days) are automatically deleted. This would allow users to retain images for a specific duration rather than a fixed count.
 
** Sized-Based Retention**: We could also implement a size-based retention policy where we monitor the total storage used by images and delete the oldest images when a certain storage threshold is reached. This would help manage disk space more effectively.

** Tiered Retention Policy**: We could implement a tiered retention policy where images are categorized into different tiers based on their importance or relevance. One example, we could have a "high-priority" tier for important images that are retained for a longer period, and a "low-priority" tier for less important images that are deleted sooner. But it is complicated to identify which are high or low priority. We could also, for example, keep all images for a certain age or number, then for images after that period or number threshold we could keep only each second image, then after a further threshold we could keep only each 5th of the saved so far - so each 10th of the original one. 

We could also combine. Brainstorm a bit and provide few suggestions how to approach this problem.
